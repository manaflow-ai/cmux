@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The browser import's reads on the daemon (`browser_import.read`): the fields each read sends,
/// the replies it takes, and the private copy it names for a folder macOS protects. The
/// readers' own rules are the cmux-browser-import crate's tests.
@Suite(.serialized) struct BrowserDataReaderTests {
    /// Every request sent, and the reply each gets.
    private actor Wire {
        /// Each request's fields as JSON (``fields(_:)`` reads one).
        private(set) var requests: [Data] = []
        /// Files the daemon saw at each path it was sent (a staged copy is gone after the read).
        private(set) var present: [String: Bool] = [:]
        let reply: @Sendable ([String: Any]) -> Any

        init(reply: @escaping @Sendable ([String: Any]) -> Any) { self.reply = reply }

        func answer(_ request: Data) throws -> Data {
            let fields = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
            requests.append(request)
            for key in ["path", "profile"] {
                if let path = fields[key] as? String { present[path] = FileManager.default.fileExists(atPath: path) }
            }
            return try JSONSerialization.data(withJSONObject: reply(fields), options: [.fragmentsAllowed])
        }
    }

    private static func fields(_ request: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request) as? [String: Any]) ?? [:]
    }

    private static func sent(_ wire: Wire) async -> [[String: Any]] {
        await wire.requests.map(fields)
    }

    private static func reader(_ wire: Wire, home: URL = URL(fileURLWithPath: "/nonexistent-home")) -> BrowserDataReader {
        BrowserDataReader(copies: ProtectedProfileCopy(home: home)) { try await wire.answer($0) }
    }

    private static func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func historyNamesItsReaderAndDecodesTheDaemonsShape() async throws {
        let wire = Wire { _ in
            let rows: [[String: Any]] = [["url": "https://a.example/", "title": "A", "visitCount": 3, "lastVisit": 10.0],
                                         ["url": "", "visitCount": 1, "lastVisit": 0.0]]
            return ["ok": rows] as [String: Any]
        }
        let entries = try await Self.reader(wire).history(.chromium, file: URL(fileURLWithPath: "/tmp/History"), limit: 7)
        #expect(entries.map(\.url.absoluteString) == ["https://a.example/"], "an entry URL refuses is skipped")
        #expect(entries.first?.lastVisit == Date(timeIntervalSinceReferenceDate: 10))
        let sent = await Self.sent(wire)
        #expect(sent.first?["reader"] as? String == "chromium.history")
        #expect(sent.first?["path"] as? String == "/tmp/History")
        #expect(sent.first?["limit"] as? Int == 7)
        // WebKit stores have no history reader: nothing is asked.
        #expect(try await Self.reader(wire).history(.webkit, file: URL(fileURLWithPath: "/tmp/x"), limit: 1).isEmpty)
        #expect(await Self.sent(wire).count == 1)
    }

    @Test func aSourceThatDoesNotReadThrowsItsKind() async throws {
        let wire = Wire { _ in ["error": ["kind": "notBookmarks", "message": "no roots"]] as [String: Any] }
        let profile = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Default",
                                           path: URL(fileURLWithPath: "/tmp/Default"), availability: [:])
        await #expect(throws: BrowserDataReader.Failure(kind: "notBookmarks", message: "no roots")) {
            try await Self.reader(wire).bookmarks(profile)
        }
        #expect(await Self.sent(wire).first?["reader"] as? String == "chromium.bookmarks")
        #expect(await Self.sent(wire).first?["path"] as? String == "/tmp/Default/Bookmarks")
    }

    @Test func openTabsFindTheSessionFileThenReadIt() async throws {
        let wire = Wire { fields in
            let file: [String: Any] = ["ok": "/tmp/p/sessionstore.jsonlz4"]
            let tabs: [String: Any] = ["ok": [["url": "https://a.example/", "window": 0, "pinned": true]]]
            return fields["reader"] as? String == "firefox.session_file" ? file : tabs
        }
        let profile = BrowserSourceProfile(browser: .firefox, directoryName: "p", displayName: "p",
                                           path: URL(fileURLWithPath: "/tmp/p"), availability: [:])
        let tabs = try await Self.reader(wire).openTabs(profile)
        #expect(tabs == [ImportedTab(url: try #require(URL(string: "https://a.example/")), title: nil, window: 0, pinned: true)])
        #expect(await Self.sent(wire).compactMap { $0["reader"] as? String } == ["firefox.session_file", "firefox.session"])
        #expect(await Self.sent(wire).last?["path"] as? String == "/tmp/p/sessionstore.jsonlz4")
    }

    @Test func searchEngineSettingAndExportedHistory() async throws {
        let wire = Wire { fields in
            switch fields["reader"] as? String {
            case "search_engine.setting": return ["ok": ["engine": "duckduckgo"]] as [String: Any]
            case "exported_history.looks_like": return ["ok": true] as [String: Any]
            default:
                let entry: [String: Any] = ["url": "https://a.example/", "visitCount": 2, "lastVisit": 1.0]
                return ["ok": ["format": "chromeTakeout", "entries": [entry]] as [String: Any]] as [String: Any]
            }
        }
        let reader = Self.reader(wire)
        let engine = ImportedSearchEngine(name: "DDG", search: "https://duckduckgo.com/?q={searchTerms}")
        let setting = try await reader.setting(engine, builtIn: ["duckduckgo": "https://duckduckgo.com/?q={searchTerms}"])
        #expect(setting == BrowserDataReader.SearchSetting(engine: "duckduckgo", search: nil, suggest: nil))
        let sentEngine = await Self.sent(wire).first?["engine"] as? [String: Any]
        #expect(sentEngine?["name"] as? String == "DDG")
        #expect(await reader.looksLikeHistory("{\"history\""))
        let json = Data(#"{"Browser History": []}"#.utf8)
        let exported = try #require(try await reader.exportedHistory(json))
        #expect(exported.format == .chromeTakeout)
        #expect(exported.entries.map(\.visitCount) == [2])
        #expect(await Self.sent(wire).last?["base64"] as? String == json.base64EncodedString())
    }

    @Test func aProtectedProfileIsReadFromAPrivateCopy() async throws {
        let home = try Self.temporary("protected-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appending(path: "Library/Group Containers/com.alohabrowser.alohabrowser/Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile.appending(path: "Extensions/abc/1.0/_locales/en"), withIntermediateDirectories: true)
        for name in ["Preferences", "Web Data", "Web Data-wal", "Login Data", "Extensions/abc/1.0/manifest.json",
                     "Extensions/abc/1.0/_locales/en/messages.json", "Extensions/abc/1.0/background.js"] {
            try Data("x".utf8).write(to: profile.appending(path: name))
        }
        let wire = Wire { _ in ["ok": [Any]()] }
        let source = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Default", path: profile, availability: [:])
        _ = try await Self.reader(wire, home: home).extensions(source)
        let sent = try #require(await Self.sent(wire).first?["profile"] as? String)
        #expect(!sent.hasPrefix(home.path), "the daemon is named a copy, never the protected folder")
        #expect(await wire.present[sent] == true)
        #expect(!FileManager.default.fileExists(atPath: sent), "the copy is gone after the read")

        // What a copy holds: the listed files, never Login Data or an extension's code.
        let copies = ProtectedProfileCopy(home: home)
        let held = try await copies.profile(profile) { folder in
            (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
        }
        #expect(held == ["Extensions", "Extensions/abc", "Extensions/abc/1.0", "Extensions/abc/1.0/_locales",
                         "Extensions/abc/1.0/_locales/en", "Extensions/abc/1.0/_locales/en/messages.json",
                         "Extensions/abc/1.0/manifest.json", "Preferences", "Web Data", "Web Data-wal"])

        // An unprotected profile is named as it is.
        let plain = try Self.temporary("plain-profile")
        defer { try? FileManager.default.removeItem(at: plain) }
        let open = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Default", path: plain, availability: [:])
        _ = try await Self.reader(wire, home: home).extensions(open)
        #expect(await Self.sent(wire).last?["profile"] as? String == plain.path)
    }
}

/// The fixed list of what the app copies out of a folder macOS protects: pinned, so a change
/// to it is a reviewed change (nothing here parses a file; the readers are the daemon's).
struct ProtectedProfileCopyTests {
    @Test func theCopyListIsPinned() {
        #expect(ProtectedProfileCopy.protectedFolders == ["Library/Safari", "Library/SafariTechnologyPreview", "Library/Containers",
                                                          "Library/Group Containers"])
        #expect(ProtectedProfileCopy.profileFiles == [
            "Preferences", "Secure Preferences", "Web Data", "Bookmarks", "History", "Current Session", "places.sqlite",
            "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4",
            "search.json.mozlz4",
        ])
        #expect(ProtectedProfileCopy.profileFolders == ["Sessions"])
        #expect(ProtectedProfileCopy.databaseSidecars == ["-wal", "-journal"])
    }

    @Test func protectedFoldersAreTheHomesAsWrittenOrLinked() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let copies = ProtectedProfileCopy(home: home)
        #expect(copies.isProtected(home.appending(path: "Library/Safari/History.db")))
        #expect(copies.isProtected(home.appending(path: "library/SAFARI/History.db")))
        #expect(copies.isProtected(home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Safari/Bookmarks.plist")))
        #expect(copies.isProtected(home.appending(path: "Library/Group Containers/g/Default")))
        #expect(!copies.isProtected(home.appending(path: "Library/Application Support/Google/Chrome/Default")))
        #expect(!copies.isProtected(home.appending(path: "Library/SafariTechnologyPreviewNot")))
    }
}

@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The browser import's reads on the daemon (`browser_import.read`): the fields each read sends,
/// the replies it takes, and the upload it sends for a folder macOS protects. The
/// readers' own rules are the cmux-browser-import crate's tests.
@Suite(.serialized) struct BrowserDataReaderTests {
    /// Every request sent, and the reply each gets.
    private actor Wire {
        /// Each request's fields as JSON (``fields(_:)`` reads one).
        private(set) var requests: [Data] = []
        let reply: @Sendable ([String: Any]) -> Any

        init(reply: @escaping @Sendable ([String: Any]) -> Any) { self.reply = reply }

        func answer(_ request: Data) throws -> Data {
            let fields = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
            requests.append(request)
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
        BrowserDataReader(protected: ProtectedProfileUpload(home: home)) { try await wire.answer($0) }
    }

    private static func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func historyNamesItsReaderAndDecodesTheDaemonsShape() async throws {
        let wire = Wire { _ in
            let rows: [[String: Any]] = [["url": "https://a.example/", "title": "A", "visitCount": 3, "lastVisit": 10.0],
                                         ["url": 42, "visitCount": 1, "lastVisit": 0.0]]
            return ["ok": rows] as [String: Any]
        }
        let entries = try await Self.reader(wire).history(.chromium, file: URL(fileURLWithPath: "/tmp/History"), limit: 7)
        #expect(entries.map(\.url.absoluteString) == ["https://a.example/"], "an entry whose URL does not decode is skipped")
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

    @Test func aProtectedProfileIsSentIntoAnUploadNeverCopiedToDisk() async throws {
        let home = try Self.temporary("protected-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appending(path: "Library/Group Containers/com.alohabrowser.alohabrowser/Default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile.appending(path: "Extensions/abc/1.0/_locales/en"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile.appending(path: "Sessions"), withIntermediateDirectories: true)
        for name in ["Preferences", "Web Data", "Web Data-wal", "Web Data-journal", "Login Data", "Sessions/Session_3",
                     "Extensions/abc/1.0/manifest.json", "Extensions/abc/1.0/_locales/en/messages.json", "Extensions/abc/1.0/background.js"] {
            try Data("x".utf8).write(to: profile.appending(path: name))
        }
        // A file over one chunk goes in several appends.
        try Data(count: ProtectedProfileUpload.chunkBytes + 5).write(to: profile.appending(path: "History"))
        let wire = Wire { _ in ["ok": [Any]()] }
        let source = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Default", path: profile, availability: [:])
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        _ = try await Self.reader(wire, home: home).extensions(source)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        #expect(after.subtracting(before).filter { $0.hasPrefix("cmux-import-") }.isEmpty, "nothing is staged on disk")
        let sent = await Self.sent(wire)
        let appends = sent.filter { $0["reader"] as? String == "upload.append" }
        let id = try #require(appends.first?["upload"] as? String)
        #expect(appends.allSatisfy { $0["upload"] as? String == id })
        // What an upload holds: the listed files, never Login Data, a journal or an extension's code.
        #expect(Set(appends.compactMap { $0["name"] as? String }) == [
            "Preferences", "Web Data", "Web Data-wal", "History", "Sessions/Session_3",
            "Extensions/abc/1.0/manifest.json", "Extensions/abc/1.0/_locales/en/messages.json",
        ])
        #expect(appends.filter { $0["name"] as? String == "History" }.count == 2)
        let read = try #require(sent.first { $0["reader"] as? String == "chromium.extensions" })
        #expect(read["profile"] as? String == ".")
        #expect(read["upload"] as? String == id)
        #expect(sent.last?["reader"] as? String == "upload.drop", "the upload is dropped after the read")
        #expect(sent.last?["upload"] as? String == id)
        #expect(!sent.contains { ($0["path"] as? String ?? $0["profile"] as? String ?? "").hasPrefix(home.path) },
                "the daemon is never named the protected folder")

        // An upload the daemon refuses (over its cap) throws, and is still dropped.
        let refusing = Wire { fields in
            let refused: [String: Any] = ["error": ["kind": "tooLarge", "message": "over"]]
            return fields["reader"] as? String == "upload.append" ? refused : ["ok": NSNull()] as [String: Any]
        }
        await #expect(throws: BrowserDataReader.Failure.self) { _ = try await Self.reader(refusing, home: home).extensions(source) }
        #expect(await Self.sent(refusing).last?["reader"] as? String == "upload.drop")

        // An unprotected profile is named as it is.
        let plain = try Self.temporary("plain-profile")
        defer { try? FileManager.default.removeItem(at: plain) }
        let open = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Default", path: plain, availability: [:])
        _ = try await Self.reader(wire, home: home).extensions(open)
        #expect(await Self.sent(wire).last?["profile"] as? String == plain.path)
        #expect(await Self.sent(wire).last?["upload"] == nil)
    }
}

/// The fixed list of what the app sends from a folder macOS protects: pinned, so a change
/// to it is a reviewed change (nothing here parses a file; the readers are the daemon's).
struct ProtectedProfileUploadTests {
    @Test func theUploadListIsPinned() {
        #expect(ProtectedProfileUpload.protectedFolders == ["Library/Safari", "Library/SafariTechnologyPreview", "Library/Containers",
                                                          "Library/Group Containers"])
        #expect(ProtectedProfileUpload.profileFiles == [
            "Preferences", "Secure Preferences", "Web Data", "Bookmarks", "History", "Current Session", "places.sqlite",
            "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4",
            "search.json.mozlz4",
        ])
        #expect(ProtectedProfileUpload.profileFolders == ["Sessions"])
        #expect(ProtectedProfileUpload.databaseSidecars == ["-wal"])
        #expect(ProtectedProfileUpload.chunkBytes == 2 << 20)
    }

    @Test func protectedFoldersAreTheHomesAsWrittenOrLinked() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let copies = ProtectedProfileUpload(home: home)
        #expect(copies.isProtected(home.appending(path: "Library/Safari/History.db")))
        #expect(copies.isProtected(home.appending(path: "library/SAFARI/History.db")))
        #expect(copies.isProtected(home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Safari/Bookmarks.plist")))
        #expect(copies.isProtected(home.appending(path: "Library/Group Containers/g/Default")))
        #expect(!copies.isProtected(home.appending(path: "Library/Application Support/Google/Chrome/Default")))
        #expect(!copies.isProtected(home.appending(path: "Library/SafariTechnologyPreviewNot")))
        #expect(!copies.isProtected(home.appending(path: "Library/SafariX/History.db")))
        #expect(!copies.isProtected(home.appending(path: "Library/ContainersX/x")))
        #expect(copies.isProtected(home.appending(path: "Library/SafariTechnologyPreview/History.db")))
    }
}

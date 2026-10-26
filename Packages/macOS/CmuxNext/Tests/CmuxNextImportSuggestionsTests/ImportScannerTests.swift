import CmuxNextBrowserImport
@testable import CmuxNextImportSuggestions
import Foundation
import Testing

/// The scan behind the import cards: what it finds from folder listings and
/// file existence in a fixture home, and what it leaves alone.
struct ImportScannerTests {
    /// A scratch home with files made by `paths` (empty files, folders made on the way).
    final class Home {
        let url: URL

        init(_ paths: [String] = []) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "import-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
            for path in paths { try write(path) }
        }

        func write(_ path: String, _ data: Data = Data("x".utf8)) throws {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static func scanner(_ home: Home, imported: Set<String> = [], classic: Int? = nil,
                        probe: @escaping @Sendable (URL) -> FileAccess = FileAccess.probe) -> ImportScanner {
        ImportScanner(home: home.url, environment: ImportEnvironment(homeDirectory: home.url, locateApp: { _ in nil }),
                      variables: [:], importedProfiles: imported, classicWorkspaces: { classic }, probe: probe)
    }

    static let chrome = "Library/Application Support/Google/Chrome"

    @Test func chromeProfilesAndKindsComeFromFileExistence() throws {
        let home = try Home([
            "\(Self.chrome)/Default/History", "\(Self.chrome)/Default/Bookmarks", "\(Self.chrome)/Default/Network/Cookies",
            "\(Self.chrome)/Profile 2/History", "\(Self.chrome)/Profile 1/Cookies",
            // Not profiles: Chrome's own folders.
            "\(Self.chrome)/Guest Profile/History", "\(Self.chrome)/System Profile/History", "\(Self.chrome)/Local State",
        ])
        let chrome = try #require(Self.scanner(home).browsers().first { $0.browser == .chrome })
        #expect(chrome.profiles.map(\.directoryName) == ["Default", "Profile 1", "Profile 2"])
        #expect(chrome.profiles[0].kinds == [.history, .bookmarks, .cookies])
        #expect(chrome.profiles[1].kinds == [.cookies])
        #expect(chrome.kinds == [.history, .bookmarks, .cookies])
        #expect(chrome.access == .ready)
    }

    @Test func aProfileImportedBeforeIsLeftOut() throws {
        let home = try Home(["\(Self.chrome)/Default/History", "\(Self.chrome)/Profile 1/History"])
        let chrome = try #require(Self.scanner(home, imported: ["chrome/Default"]).browsers().first { $0.browser == .chrome })
        #expect(chrome.profiles.map(\.directoryName) == ["Profile 1"])
        let none = Self.scanner(home, imported: ["chrome/Default", "chrome/Profile 1"]).browsers()
        #expect(!none.contains { $0.browser == .chrome })
    }

    /// Browser import turned off while a scan runs: the scan reads no further source once told to stop.
    @Test func aScanToldToStopReadsNoFurtherSource() throws {
        let home = try Home(["\(Self.chrome)/Default/History", "Library/Application Support/zen/Profiles/a.default/places.sqlite",
                             ".claude/projects/p/s.jsonl"])
        let stops = StopAfter(1)
        var scanner = Self.scanner(home)
        scanner.shouldStop = { stops.ask() }
        let found = scanner.scan()
        #expect(found.map(\.browser) == [.chrome], "only the source before the stop was read: \(found.map(\.id))")
        // Told to stop before it starts, it reads nothing.
        scanner.shouldStop = { true }
        #expect(scanner.scan().isEmpty)
        // Never told: every source.
        let all = Self.scanner(home).scan()
        #expect(all.contains { $0.browser == .zen } && all.contains { $0.kind == .claudeCode }, "\(all.map(\.id))")
    }

    /// `shouldStop` that answers false `count` times, then true.
    final class StopAfter: @unchecked Sendable {
        private var left: Int
        private let lock = NSLock()

        init(_ count: Int) { left = count }

        func ask() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            left -= 1
            return left < 0
        }
    }

    @Test func firefoxFamilyProfilesComeFromTheProfilesFolder() throws {
        let home = try Home([
            "Library/Application Support/zen/Profiles/ab12.Default (release)/places.sqlite",
            "Library/Application Support/zen/Profiles/ab12.Default (release)/cookies.sqlite",
            "Library/Application Support/zen/Profiles/empty.old/prefs.js",
        ])
        let zen = try #require(Self.scanner(home).browsers().first { $0.browser == .zen })
        #expect(zen.profiles.map(\.directoryName) == ["Profiles/ab12.Default (release)"])
        // `kinds` is in ImportDataKind order.
        #expect(zen.kinds == [.history, .bookmarks, .cookies])
    }

    @Test func safariBehindFullDiskAccessIsFoundWithoutReadingIt() throws {
        let home = try Home()
        let denied = Self.scanner(home) { url in url.lastPathComponent == "History.db" ? .denied : .missing }
        let safari = try #require(denied.browsers().first { $0.browser == .safari })
        #expect(safari.access == .needsFullDiskAccess)
        let missing = Self.scanner(home) { _ in .missing }
        #expect(!missing.browsers().contains { $0.browser == .safari })
    }

    @Test func agentSessionsAreCountedFromListings() throws {
        let home = try Home([
            ".claude/projects/-Users-me-a/1.jsonl", ".claude/projects/-Users-me-a/2.jsonl", ".claude/projects/-Users-me-b/3.jsonl",
            ".claude/projects/-Users-me-b/notes.txt",
            ".codex/sessions/2026/10/19/rollout-1.jsonl", ".codex/sessions/2026/10/20/rollout-2.jsonl",
        ])
        let found = Self.scanner(home).scan()
        #expect(found.first { $0.kind == .claudeCode }?.count == 3)
        #expect(found.first { $0.kind == .codex }?.count == 2)
    }

    @Test func nothingFoundMeansNoCards() throws {
        let home = try Home()
        #expect(Self.scanner(home) { _ in .missing }.scan().isEmpty)
    }

    @Test func ghosttyIsInUseAndClassicCountsItsWorkspaces() throws {
        let home = try Home([".config/ghostty/config"])
        let found = Self.scanner(home, classic: 7) { _ in .missing }.scan()
        #expect(found.first { $0.kind == .ghostty }?.access == .inUse)
        #expect(found.first { $0.kind == .cmuxClassic }?.count == 7)
    }

    /// Classic has a saved session and all of it is already here: the card stays (Settings ›
    /// Import offers the import again); no saved session means no card.
    @Test func classicWithEverythingHereIsStillFound() throws {
        let home = try Home()
        let found = Self.scanner(home, classic: 0) { _ in .missing }.scan()
        #expect(found.first { $0.kind == .cmuxClassic }?.count == 0)
        #expect(Self.scanner(home, classic: nil) { _ in .missing }.scan().allSatisfy { $0.kind != .cmuxClassic })
    }

    @Test func iTermProfilesAndTheirColors() throws {
        let color = { (r: Double, g: Double, b: Double) in ["Red Component": r, "Green Component": g, "Blue Component": b] }
        let plist: [String: Any] = [
            "Default Bookmark Guid": "B",
            "New Bookmarks": [
                ["Name": "Work", "Guid": "A", "Background Color": color(1, 1, 1)],
                ["Name": "Default", "Guid": "B", "Background Color": color(0, 0, 0), "Ansi 1 Color": color(1, 0, 0),
                 "Foreground Color (Dark)": color(0.5, 0.5, 0.5)],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let home = try Home()
        try home.write("Library/Preferences/com.googlecode.iterm2.plist", data)
        let iterm = try #require(Self.scanner(home) { _ in .missing }.scan().first { $0.kind == .iterm2 })
        #expect(iterm.count == 2)
        let preferred = try #require(ITermProfiles(data: data)?.preferred)
        #expect(preferred.name == "Default")
        #expect(preferred.themeLines == ["palette = 1=#ff0000", "background = #000000", "foreground = #808080"])
    }

    @Test func aFingerprintIgnoresGrowthButNotANewProfile() {
        let one = ImportFinding(id: "browser.chrome", kind: .browser, browser: .chrome, name: "Chrome",
                                profiles: [.init(directoryName: "Default", kinds: [.history])])
        var two = one
        two.profiles.append(.init(directoryName: "Profile 1", kinds: [.history]))
        #expect(one.fingerprint != two.fingerprint)
        let claude = ImportFinding(id: "agents.claudeCode", kind: .claudeCode, name: "Claude Code", count: 10)
        var more = claude
        more.count = 500
        #expect(claude.fingerprint == more.fingerprint)
    }
}

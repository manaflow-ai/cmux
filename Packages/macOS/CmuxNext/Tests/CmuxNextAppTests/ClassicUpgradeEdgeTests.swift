@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Upgrade hitches found by the classic upgrade simulations
/// (``ClassicUpgradeSimulationTests``), each at the smallest seam that shows it:
/// whether classic still runs, scrollback after classic crashed, a session past
/// the old 64 MB cap, and a channel whose session file is gone but its copy is not.
@Suite final class ClassicUpgradeEdgeTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cn-edge-\(UUID().uuidString.prefix(8))")

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func classicFolder() throws -> URL {
        let cmux = folder.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmux, withIntermediateDirectories: true)
        return cmux
    }

    // MARK: Classic running

    private func source(savedSecondsAgo age: Double, now: Double, bundle: String = "com.cmuxterm.app") -> ClassicMigrationSource {
        ClassicMigrationSource(path: "/s/session-\(bundle).json", bundleID: bundle, size: 10, modifiedAt: now - age, createdAt: now - age)
    }

    private func sentinel(_ probe: ClassicRunningProbe, channel: String) throws {
        let url = probe.sentinel(channel: channel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pid=4242\n".utf8).write(to: url)
    }

    /// The Sparkle update relaunch: classic quit cleanly (no sentinel) two seconds ago.
    @Test func aClassicThatJustQuitIsNotRunning() {
        let probe = ClassicRunningProbe(stateRoot: folder.appendingPathComponent("state"))
        #expect(!probe.isRunning(source(savedSecondsAgo: 2, now: 1_891_000_000), now: 1_891_000_000))
    }

    /// Classic is open (its sentinel is there and it saved within the last 90 s).
    @Test func aClassicWithItsSentinelAndARecentSaveIsRunning() throws {
        let probe = ClassicRunningProbe(stateRoot: folder.appendingPathComponent("state"))
        try sentinel(probe, channel: "com.cmuxterm.app")
        #expect(probe.isRunning(source(savedSecondsAgo: 5, now: 1_891_000_000), now: 1_891_000_000))
        // It crashed: the sentinel stayed, the autosaves stopped.
        #expect(!probe.isRunning(source(savedSecondsAgo: 600, now: 1_891_000_000), now: 1_891_000_000))
    }

    /// Only the session's own channel's sentinel counts.
    @Test func anotherChannelsSentinelDoesNotCount() throws {
        let probe = ClassicRunningProbe(stateRoot: folder.appendingPathComponent("state"))
        try sentinel(probe, channel: "com.cmuxterm.app.nightly")
        #expect(!probe.isRunning(source(savedSecondsAgo: 5, now: 1_891_000_000), now: 1_891_000_000))
        #expect(probe.isRunning(source(savedSecondsAgo: 5, now: 1_891_000_000, bundle: "com.cmuxterm.app.nightly"), now: 1_891_000_000))
    }

    /// Classic's state folder follows `XDG_STATE_HOME`, as classic does.
    @Test func theStateFolderFollowsXDGStateHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ClassicRunningProbe.defaultStateRoot(home: home, environment: [:]).path == "/Users/someone/.local/state/cmux")
        #expect(ClassicRunningProbe.defaultStateRoot(home: home, environment: ["XDG_STATE_HOME": "/x/state"]).path == "/x/state/cmux")
    }

    // MARK: Scrollback checkpoints

    private func session(panel: String, inline: String?, extraPanel: String? = nil) -> Data {
        func terminal(_ id: String, _ scrollback: String?) -> [String: Any] {
            var terminal: [String: Any] = ["workingDirectory": "/tmp"]
            if let scrollback { terminal["scrollback"] = scrollback }
            return ["id": id, "type": "terminal", "terminal": terminal]
        }
        var panels = [terminal(panel, inline)]
        var ids = [panel]
        if let extraPanel {
            panels.append(terminal(extraPanel, nil))
            ids.append(extraPanel)
        }
        let workspace: [String: Any] = ["stableId": "S1", "customTitle": "t", "currentDirectory": "/tmp", "panels": panels,
                                        "layout": ["type": "pane", "pane": ["panelIds": ids]]]
        let root: [String: Any] = ["version": 1, "windows": [["tabManager": ["workspaces": [workspace]]]]]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func checkpoint(_ panel: String, _ text: String, in folder: URL, fileName: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: [String: Any] = ["version": 1, "panelId": panel, "capturedAt": 1_891_000_000.0, "scrollback": text]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: folder.appendingPathComponent(fileName ?? "\(panel).json"))
    }

    private func scrollbacks(_ snapshot: ClassicSessionSnapshot) -> [String?] {
        snapshot.workspaces.flatMap(\.layout.tabs).map(\.scrollback)
    }

    /// Classic crashed (or was force quit, or the Mac lost power): its last
    /// save is an autosave without scrollback, and the history is in its checkpoints.
    @Test func aCrashedClassicsScrollbackComesFromItsCheckpoints() throws {
        let cmux = try classicFolder()
        let file = cmux.appendingPathComponent("session-com.cmuxterm.app.json")
        let panel = "6F1C2B8E-0D4B-4C55-9E55-1D2F3A4B5C6D"
        try session(panel: panel, inline: nil).write(to: file)
        let folder = try #require(ClassicSessionImporter.checkpointFolder(for: file))
        #expect(folder.lastPathComponent == "session-com.cmuxterm.app-scrollback")
        try checkpoint(panel, "$ make test\r\nok", in: folder)
        let snapshot = try #require(try ClassicSessionImporter(fileURL: file).readSnapshot())
        #expect(scrollbacks(snapshot) == ["$ make test\r\nok"])
    }

    /// A quit save carries the scrollback itself: a stale checkpoint never
    /// replaces it, nor fills a terminal the quit save left empty (classic's rule).
    @Test func aQuitSavesOwnScrollbackWins() throws {
        let cmux = try classicFolder()
        let file = cmux.appendingPathComponent("session-com.cmuxterm.app.json")
        let panel = "6F1C2B8E-0D4B-4C55-9E55-1D2F3A4B5C6D", empty = "7A1C2B8E-0D4B-4C55-9E55-1D2F3A4B5C6D"
        try session(panel: panel, inline: "from quit", extraPanel: empty).write(to: file)
        let folder = try #require(ClassicSessionImporter.checkpointFolder(for: file))
        try checkpoint(panel, "stale", in: folder)
        try checkpoint(empty, "stale too", in: folder)
        let snapshot = try #require(try ClassicSessionImporter(fileURL: file).readSnapshot())
        #expect(scrollbacks(snapshot) == ["from quit", nil])
    }

    /// The `-previous` copy uses the channel's checkpoints; an archive uses none.
    /// A file named for one panel that records another is not used.
    @Test func checkpointsAreTheChannelsAndMatchTheirPanel() throws {
        let cmux = try classicFolder()
        let previous = cmux.appendingPathComponent("session-com.cmuxterm.app.nightly-previous.json")
        #expect(ClassicSessionImporter.checkpointFolder(for: previous)?.lastPathComponent == "session-com.cmuxterm.app.nightly-scrollback")
        let archive = cmux.appendingPathComponent("session-history/session-com.cmuxterm.app-1891000000000-w1-p2.json")
        #expect(ClassicSessionImporter.checkpointFolder(for: archive) == nil)

        let panel = "6f1c2b8e-0d4b-4c55-9e55-1d2f3a4b5c6d"
        try session(panel: panel, inline: nil).write(to: previous)
        let folder = try #require(ClassicSessionImporter.checkpointFolder(for: previous))
        // Classic names the file with the UUID's upper-case string.
        try checkpoint(panel.uppercased(), "kept", in: folder)
        #expect(scrollbacks(try #require(try ClassicSessionImporter(fileURL: previous).readSnapshot())) == ["kept"])
        try checkpoint("00000000-0000-4000-8000-000000000000", "someone else's", in: folder, fileName: "\(panel.uppercased()).json")
        #expect(scrollbacks(try #require(try ClassicSessionImporter(fileURL: previous).readSnapshot())) == [nil])
    }

    // MARK: Size

    /// A heavy user's quit save: 200 terminals with classic's full 4000-line
    /// scrollback is over 64 MB. Classic restores it, so the upgrade reads it.
    @Test func aHeavyQuitSaveOverSixtyFourMegabytesStillReads() throws {
        let cmux = try classicFolder()
        let file = cmux.appendingPathComponent("session-com.cmuxterm.app.json")
        let full = ClassicUpgradeProfile.scrollback(lines: 4000)
        let windows: [ClassicUpgradeProfile.Window] = (0..<2).map { window in
            let workspaces: [ClassicUpgradeProfile.Workspace] = (0..<100).map { index in
                ClassicUpgradeProfile.Workspace(title: "heavy \(window)-\(index)", layout: .pane([.terminal(scrollback: full)]))
            }
            return ClassicUpgradeProfile.Window(workspaces: workspaces)
        }
        let profile = ClassicUpgradeProfile(name: "heavy", windows: windows)
        try profile.sessionData(home: folder.path).write(to: file)
        let size = try #require((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? NSNumber).intValue
        #expect(size > 64 * 1024 * 1024, "\(size) bytes")
        let snapshot = try #require(try ClassicSessionImporter(fileURL: file).readSnapshot())
        #expect(snapshot.workspaces.count == 200)
        #expect(snapshot.workspaces.allSatisfy { $0.layout.tabs.first?.scrollback?.isEmpty == false })
    }

    // MARK: Finding the session

    /// Classic's session file is gone (a cleanup, a failed write), its launch copy is not.
    @Test func aChannelWithOnlyItsPreviousCopyIsStillFound() throws {
        let cmux = try classicFolder()
        try Data("{}".utf8).write(to: cmux.appendingPathComponent("session-com.cmuxterm.app-previous.json"))
        let finder = ClassicMigrationSourceFinder(support: folder, ownBundleID: "com.cmuxterm.app")
        #expect(finder.channel() == "com.cmuxterm.app")
        #expect(finder.candidates().map(\.url.lastPathComponent) == ["session-com.cmuxterm.app-previous.json"])
    }

    // MARK: Names

    /// cmux-next refuses a workspace name over 1024 bytes; classic took any
    /// title. A long one comes over cut at a character, still unique.
    @Test func aNameOverTheDaemonsLimitIsCutAndStaysUnique() throws {
        let long = String(repeating: "long ", count: 400)
        let emoji = String(repeating: "🚀", count: 300)
        let clues = [long, long, emoji].map {
            ClassicSessionImporter.NameClues(custom: $0, titles: [], agent: nil, branch: nil, folder: "f")
        }
        let names = ClassicSessionImporter.names(clues)
        #expect(names.allSatisfy { $0.utf8.count <= ClassicSessionImporter.maximumNameBytes }, "\(names.map(\.utf8.count))")
        #expect(Set(names).count == 3)
        #expect(long.hasPrefix(names[0]) && names[2].allSatisfy { $0 == "🚀" })
    }
}

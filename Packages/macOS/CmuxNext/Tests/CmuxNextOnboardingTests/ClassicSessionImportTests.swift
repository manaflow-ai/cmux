import Foundation
import Testing
@testable import CmuxNextOnboarding

@Suite struct ClassicSessionImportTests {
    @Test func decodesWorkspaceNamesDirectoriesTabsAndSplitTopology() throws {
        let json = """
        {"version":1,"windows":[{"tabManager":{"workspaces":[{
          "processTitle":"Project Alpha","currentDirectory":"/work/alpha",
          "layout":{"type":"split","split":{"orientation":"vertical","dividerPosition":0.35,
            "first":{"type":"pane","pane":{"panelIds":["a"]}},
            "second":{"type":"pane","pane":{"panelIds":["b","c"]}}}},
          "panels":[
            {"id":"a","customTitle":"Editor","terminal":{"workingDirectory":"/work/alpha/src"}},
            {"id":"b","title":"Logs","terminal":{"workingDirectory":"/work/alpha"}},
            {"id":"c","customTitle":"Tests","terminal":{"workingDirectory":"/work/alpha"}}
          ]
        }]}}]}
        """.data(using: .utf8)!
        let workspaces = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/fixture")).decode(json)
        #expect(workspaces.count == 1)
        #expect(workspaces[0].name == "Project Alpha")
        #expect(workspaces[0].workingDirectory == "/work/alpha")
        guard case .split(let orientation, let ratio, .pane(let first), .pane(let second)) = workspaces[0].layout else {
            Issue.record("expected a split with two panes")
            return
        }
        #expect(orientation == .vertical)
        #expect(ratio == 0.35)
        #expect(first.tabs.first?.title == "Editor")
        #expect(second.tabs.map(\.title) == ["Logs", "Tests"])
    }

    /// A snapshot with a panel id twice decodes (the first wins) instead of
    /// trapping, and the selected tab counts only the tabs that resolved.
    @Test func duplicatePanelIdsAndMissingPanelsDecode() throws {
        let json = """
        {"windows":[{"tabManager":{"workspaces":[{
          "customTitle":"Dupes","currentDirectory":"/work",
          "layout":{"type":"pane","pane":{"panelIds":["gone","a","b"],"selectedPanelId":"b"}},
          "panels":[
            {"id":"a","title":"First","terminal":{"workingDirectory":"/work/a"}},
            {"id":"a","title":"Second","terminal":{"workingDirectory":"/work/a2"}},
            {"id":"b","title":"Other","terminal":{"workingDirectory":"/work/b"}}
          ]
        }]}}]}
        """.data(using: .utf8)!
        let workspaces = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/fixture")).decode(json)
        guard case .pane(let pane) = workspaces.first?.layout else {
            Issue.record("expected one pane")
            return
        }
        #expect(pane.tabs.map(\.title) == ["First", "Other"])
        #expect(pane.selectedTab == 1)
    }

    /// Classic titles a home-folder shell "~": a name that is only a path
    /// gives way to the first tab's title, else the folder's name.
    @Test func aPathTitleGivesWayToTheTabOrTheFolder() throws {
        let json = """
        {"windows":[{"tabManager":{"workspaces":[
          {"customTitle":"Mine","processTitle":"~","currentDirectory":"/Users/me",
           "panels":[{"id":"a","title":"vim","terminal":{"workingDirectory":"/Users/me"}}]},
          {"processTitle":"~","currentDirectory":"/Users/me",
           "panels":[{"id":"a","title":"npm run dev","terminal":{"workingDirectory":"/Users/me"}}]},
          {"processTitle":"~/code/app","currentDirectory":"/Users/me/code/app",
           "panels":[{"id":"a","title":"~/code/app","terminal":{"workingDirectory":"/Users/me/code/app"}}]},
          {"processTitle":"/tmp","currentDirectory":"/tmp","panels":[]},
          {"processTitle":"codex","currentDirectory":"/Users/me/x","panels":[]}
        ]}}]}
        """.data(using: .utf8)!
        let names = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/fixture")).decode(json).map(\.name)
        #expect(names == ["Mine", "npm run dev", "app", "tmp", "codex"])
    }

    /// Workspaces that share a folder are told apart by what ran in them,
    /// then their branch; a number is the last resort.
    @Test func workspacesInOneFolderGetNamesThatTellThemApart() throws {
        let json = """
        {"windows":[{"tabManager":{"workspaces":[
          {"processTitle":"~","currentDirectory":"/Users/me",
           "panels":[{"id":"a","title":"~"},{"id":"b","title":"nvim"}]},
          {"processTitle":"~","currentDirectory":"/Users/me",
           "panels":[{"id":"a","title":"~","terminal":{"agent":{"kind":"claude","sessionId":"s"}}}]},
          {"processTitle":"ssh big-red","currentDirectory":"/Users/me","panels":[]},
          {"processTitle":"~","currentDirectory":"/Users/me","gitBranch":{"branch":"main","isDirty":false},"panels":[]},
          {"processTitle":"~","currentDirectory":"/Users/me",
           "panels":[{"id":"a","title":"~","gitBranch":{"branch":"fix-names","isDirty":true}}]},
          {"customTitle":"api","processTitle":"~","currentDirectory":"/Users/me","panels":[]},
          {"processTitle":"~","currentDirectory":"/Users/me","panels":[]},
          {"processTitle":"~","currentDirectory":"/Users/me","panels":[]}
        ]}}]}
        """.data(using: .utf8)!
        let names = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/fixture")).decode(json).map(\.name)
        #expect(names == ["nvim", "claude", "ssh big-red", "me · main", "me · fix-names", "api", "me", "me 2"])
    }

    /// The Claude Code and Codex chats classic had open in its terminals,
    /// as chat ids; other agents and terminals without one are left out.
    @Test func openChatsAreTheAgentsClassicTerminalsRan() throws {
        let json = """
        {"windows":[{"tabManager":{"workspaces":[{
          "customTitle":"Agents","currentDirectory":"/work",
          "panels":[
            {"id":"a","terminal":{"workingDirectory":"/work","agent":{"kind":"claude","sessionId":"c-1"}}},
            {"id":"b","terminal":{"workingDirectory":"/work","agent":{"kind":"codex","sessionId":"x-2"}}},
            {"id":"c","terminal":{"workingDirectory":"/work","agent":{"kind":"gemini","sessionId":"g-3"}}},
            {"id":"d","terminal":{"workingDirectory":"/work"}}
          ]
        }]}}]}
        """.data(using: .utf8)!
        let chats = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/fixture")).openChats(json)
        #expect(chats == ["claudeCode:c-1", "codex:x-2"])
    }

    /// Classic stable and classic NIGHTLY each keep their own snapshot; the
    /// one saved last is the session to bring over.
    @Test func readsTheNewestOfStableAndNightly() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "classic-\(UUID().uuidString)")
        let folder = support.appending(path: "cmux")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ClassicSessionImporter(applicationSupport: support).fileURL.lastPathComponent == "session-com.cmuxterm.app.json")
        let stable = folder.appending(path: "session-com.cmuxterm.app.json")
        let nightly = folder.appending(path: "session-com.cmuxterm.app.nightly.json")
        try Data("{}".utf8).write(to: stable)
        try Data("{}".utf8).write(to: nightly)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stable.path)
        #expect(ClassicSessionImporter(applicationSupport: support).fileURL == nightly)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: nightly.path)
        #expect(ClassicSessionImporter(applicationSupport: support).fileURL == stable)
    }

    @Test func readsTaggedDevAndRCSnapshots() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "classic-tagged-\(UUID().uuidString)")
        let folder = support.appending(path: "cmux")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dev = folder.appending(path: "session-com.cmuxterm.app.debug.gallery.json")
        let rc = folder.appending(path: "session-com.cmuxterm.app.rc.candidate.json")
        try Data("{}".utf8).write(to: dev)
        try Data("{}".utf8).write(to: rc)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: dev.path)
        #expect(ClassicSessionImporter(applicationSupport: support).fileURL == rc)
    }

    @Test func rejectsSnapshotsOverTheReadLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "classic-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "session.json")
        try Data(repeating: 0, count: ClassicSessionImporter.maximumSnapshotBytes + 1).write(to: file)
        #expect(throws: ClassicSessionImportError.snapshotTooLarge(
            actualBytes: ClassicSessionImporter.maximumSnapshotBytes + 1,
            maximumBytes: ClassicSessionImporter.maximumSnapshotBytes
        )) {
            try ClassicSessionImporter(fileURL: file).read()
        }
    }

    @Test func missingSnapshotIsAnEmptyRead() throws {
        let importer = ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/cmux-classic-fixture-that-does-not-exist"))
        #expect(try importer.read().isEmpty)
    }
}

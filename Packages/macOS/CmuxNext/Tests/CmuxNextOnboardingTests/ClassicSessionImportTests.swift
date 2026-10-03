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

    @Test func missingSnapshotIsAnEmptyRead() throws {
        let importer = ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/tmp/cmux-classic-fixture-that-does-not-exist"))
        #expect(try importer.read().isEmpty)
    }
}

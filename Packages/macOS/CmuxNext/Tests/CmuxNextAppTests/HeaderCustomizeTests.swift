import CmuxNextAgentPane
import Foundation
import Testing

/// The chat header's right-click menu (cx-00n1): adding, removing, reordering the quick actions and
/// picking toggle or open saves the list into `agent-pane/layout.json`, the file the App watches and
/// pushes to every chat. Runs the page's `pane.setQuickActions` message as the App decodes it, then
/// the save against a real directory, read back as the App reads it.
struct HeaderCustomizeTests {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "header-customize-\(UUID().uuidString)/agent-pane")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func message(_ list: Any) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "pane.setQuickActions", "params": ["quickActions": list]])
    }

    @Test func theMenusListReplacesTheQuickActionsAndKeepsTheRestOfLayoutJSON() throws {
        let directory = try Self.directory()
        try Data(#"{"composer": {"dense": true}, "quickActions": ["terminal"]}"#.utf8)
            .write(to: directory.appending(path: "layout.json"))
        guard case .setQuickActions(let list) = Self.message([["id": "browser", "mode": "open"], ["id": "terminal", "mode": "toggle"]]) else {
            Issue.record("pane.setQuickActions did not decode")
            return
        }
        try AgentPaneCustomization.savingQuickActions(list, in: directory)
        let layout = try #require(AgentPaneCustomization(directory: directory).layoutJSON)
        #expect(layout == #"{"composer":{"dense":true},"quickActions":[{"id":"browser","mode":"open"},{"id":"terminal","mode":"toggle"}]}"#)
    }

    @Test func aFirstSaveCreatesLayoutJSON() throws {
        let directory = try Self.directory().appending(path: "new")
        guard case .setQuickActions(let list) = Self.message([]) else {
            Issue.record("an empty list did not decode")
            return
        }
        try AgentPaneCustomization.savingQuickActions(list, in: directory)
        #expect(AgentPaneCustomization(directory: directory).layoutJSON == #"{"quickActions":[]}"#)
    }

    /// A layout.json linked from a dotfiles repository stays a link, and the repository's file changes.
    @Test func aSymlinkedLayoutJSONIsWrittenThrough() throws {
        let directory = try Self.directory()
        let target = directory.deletingLastPathComponent().appending(path: "dotfiles-layout.json")
        try Data(#"{"composer": {"dense": true}}"#.utf8).write(to: target)
        let link = directory.appending(path: "layout.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .setQuickActions(let list) = Self.message([["id": "terminal", "mode": "open"]]) else {
            Issue.record("pane.setQuickActions did not decode")
            return
        }
        try AgentPaneCustomization.savingQuickActions(list, in: directory)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(AgentPaneCustomization(directory: directory).layoutJSON
            == #"{"composer":{"dense":true},"quickActions":[{"id":"terminal","mode":"open"}]}"#)
    }

    /// A layout.json the user is midway through editing is never overwritten.
    @Test func aLayoutJSONThatIsNotAnObjectIsLeftAlone() throws {
        let directory = try Self.directory()
        let file = directory.appending(path: "layout.json")
        try Data(#"{"quickActions": ["#.utf8).write(to: file)
        guard case .setQuickActions(let list) = Self.message([["id": "terminal", "mode": "toggle"]]) else {
            Issue.record("pane.setQuickActions did not decode")
            return
        }
        #expect(throws: (any Error).self) { try AgentPaneCustomization.savingQuickActions(list, in: directory) }
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"quickActions": ["#)
    }

    @Test func onlyAListOfQuickActionsReachesTheApp() {
        for bad: Any in ["terminal", [["id": "terminal", "mode": "always"]], [["id": "../x", "mode": "open"]],
                         Array(repeating: ["id": "terminal", "mode": "open"], count: 17)] {
            guard case .unsupported = Self.message(bad) else {
                Issue.record("decoded \(bad)")
                continue
            }
        }
    }
}

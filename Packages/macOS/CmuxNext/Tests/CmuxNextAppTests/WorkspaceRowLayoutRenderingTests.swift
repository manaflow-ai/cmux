import AppKit
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

@MainActor @Suite struct WorkspaceRowLayoutRenderingTests {
    static func preferences(_ json: String) throws -> WorkspaceRowPreferences {
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.diagnostics.isEmpty)
        return snapshot.sidebarSections.workspaceRow
    }

    static func workspace() -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID("layout-row"), title: "Build", directory: "~/project", branch: "feature",
                                   rowKind: .agent, kind: .harness, activity: .idle)
        row.kindBrand = "codex"
        row.agentBrand = "claude"
        row.pullRequest = "#123"
        row.reported = SidebarWorkspaceStatus(log: .init(level: .info, text: "Tests passed"))
        return row
    }

    @Test func allThreeLinesRenderAndSpeakTheirConfiguredFacts() throws {
        let preferences = try Self.preferences(#"{"sidebar":{"workspaceRow":{"lines":[["name","branch"],["directory"],["pullRequest","log"]]}}}"#)
        let workspace = Self.workspace()
        let content = WorkspaceRowContent(workspace, preferences: preferences)
        #expect(content.displayedTitle("Build") == "Build · feature")
        #expect(content.detail == "~/project")
        #expect(content.meta == "#123 · Tests passed")
        #expect(content.status == nil && content.badgeTime == nil)
        let spoken = WorkspaceRowView.accessibilityText(workspace, content: content, tabCount: nil, presence: [])
        #expect(spoken.contains("Build · feature"))
        #expect(spoken.contains("~/project"))
        #expect(spoken.contains("#123 · Tests passed"))
        _ = NSApplication.shared
        let view = WorkspaceRowView(key: .workspace(workspace.id))
        let metrics = SidebarLayoutMetrics.standard
        let row = SidebarRow(key: .workspace(workspace.id), y: 0, height: metrics.height(for: content), section: .machine(.local),
                             group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                             isCollapsed: false, childCount: 0, groupColor: nil, content: content)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: row.height)
        view.configure(workspace, row: row)
        view.layoutSubtreeIfNeeded()
        #expect(view.title.stringValue == "Build · feature")
        #expect(view.metaLabel.stringValue == "#123 · Tests passed")
        #expect(view.hasMeta && !view.metaLabel.isHidden)
        #expect(row.height == metrics.rowHeight + 2 * (metrics.rowHeightWithSubtitle - metrics.rowHeight))
    }

    @Test func frontTabAgentWinsOverAnotherWorkingAgent() throws {
        let preferences = try Self.preferences(#"{"sidebar":{"workspaceRow":{"lines":[["name"]],"linesByAgent":{"codex":[["name"],["branch"]],"claude":[["name"],["directory"]]}}}}"#)
        #expect(WorkspaceRowContent(Self.workspace(), preferences: preferences).detail == "feature")
        #expect(preferences.layouts.layout(for: .agent, agent: "unconfigured")?.lines == [["name"]])
    }

    @Test func emptyFactsLeaveNoBlankLineAndNativeTitleRulesSurvive() throws {
        let preferences = try Self.preferences(#"{"sidebar":{"workspaceRow":{"lines":[["name","branch"],["ports"],["directory"]]}}}"#)
        let content = WorkspaceRowContent(Self.workspace(), preferences: preferences)
        #expect(content.detail == "~/project" && content.meta == nil)
        #expect(content.displayedTitle("Subagent of Build") == "Subagent of Build · feature")
    }

    @Test func minimalAndTabModesKeepTheirSingleLine() throws {
        let preferences = try Self.preferences(#"{"sidebar":{"workspaceRow":{"lines":[["name","branch"],["directory"],["pullRequest"]]}}}"#)
        var options = SidebarLayoutOptions()
        options.workspaceRow = preferences
        options.minimal = true
        var content = options.rowContent(Self.workspace(), machine: nil)
        #expect(content.titleParts == nil && content.detail == nil && content.meta == nil)
        options.minimal = false
        options.workspacesAsTabs = true
        content = options.rowContent(Self.workspace(), machine: nil)
        #expect(content.titleParts == nil && content.detail == nil && content.meta == nil)
    }
}

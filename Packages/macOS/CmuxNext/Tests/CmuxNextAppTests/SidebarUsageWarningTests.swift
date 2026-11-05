import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30: "that visibility into [one agent host's] guys was (and is?) pretty bad i feel like we can
/// make more improvements to acpmux/cmux-next". A runaway agent chat (no autocompact cap, a huge
/// context, a storm of subagents) gets a small warning triangle on its sidebar row, apart from the
/// working spinner, whose tooltip says each rule acpmux found broken and the number.
@MainActor @Suite(.serialized) struct SidebarUsageWarningTests {
    static let warnings = [
        "No autocompact cap: context is 412k and only compacts at the model's limit",
        "90 subagents started in the last hour, above 40",
    ]

    static func summary(_ session: String, warnings: [String]) -> [String: Any] {
        ["sessionId": session, "name": session, "lane": ["state": "working"],
         "usageWarnings": warnings.map { ["rule": "r", "value": 1, "limit": 0, "text": $0] }]
    }

    @Test func aLaneReadsAcpmuxsWarningLines() throws {
        let lane = try #require(AgentActivityLane.of(summary: Self.summary("s", warnings: Self.warnings)))
        #expect(lane.usageWarnings == Self.warnings)
        let plain = try #require(AgentActivityLane.of(summary: ["sessionId": "p", "lane": ["state": "idle"]]))
        #expect(plain.usageWarnings.isEmpty, "an acpmux from before usageWarnings warns nothing")
    }

    /// The row takes its chats' warnings even with the lane state merge off: the warning is not a
    /// lane-status toggle's to hide.
    @Test func aRowCarriesItsChatsWarnings() throws {
        let fixture = try SidebarLaneStatusTests.Fixture()
        fixture.lanes.lanes["s-working"] = try #require(AgentActivityLane.of(summary: Self.summary("s-working", warnings: Self.warnings)))
        for on in [true, false] {
            SidebarLaneStatusTests.withLaneStatus(on) {
                let rows = Dictionary(uniqueKeysWithValues: fixture.sections().flatMap(\.workspaces).map { ($0.title, $0) })
                #expect(rows["working"]?.usageWarnings == Self.warnings, "laneStatus \(on)")
                #expect(rows["idle"]?.usageWarnings == [], "laneStatus \(on)")
            }
        }
    }

    @Test func twoChatsSayingTheSameLineShowItOnce() throws {
        let a = try #require(AgentActivityLane.of(summary: Self.summary("a", warnings: Self.warnings)))
        let b = try #require(AgentActivityLane.of(summary: Self.summary("b", warnings: [Self.warnings[1]])))
        #expect(SidebarLaneStatus.usageWarnings([a, b]) == Self.warnings)
    }

    static func rowView(_ ws: SidebarWorkspace) throws -> WorkspaceRowView {
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(ws)]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return try #require(sidebar.list.rowViews[.workspace(ws.id)] as? WorkspaceRowView)
    }

    @Test func theBadgeSaysEachRuleAndItsNumber() throws {
        var ws = SidebarWorkspace(id: WorkspaceID("ws-runaway"), title: "runaway", lastActivity: Date(), agentWorking: true,
                                  kind: .harness, activity: .working)
        ws.usageWarnings = Self.warnings
        let row = try Self.rowView(ws)
        #expect(!row.usageWarningMark.isHidden)
        #expect(row.usageWarningMark.frame.width > 0)
        #expect(row.usageWarningMark.themedToolTip == Self.warnings.joined(separator: "\n"))
        let label = try #require(row.accessibilityLabel())
        #expect(Self.warnings.allSatisfy(label.contains))
    }

    /// Hovering the row shows its ⋯ and × over the row's end; the badge stays, left of them, so a
    /// person can still point at it and read its tooltip (the first capture showed the controls in
    /// its place).
    @Test func theBadgeStaysBesideTheHoverControls() throws {
        var ws = SidebarWorkspace(id: WorkspaceID("ws-runaway"), title: "runaway", lastActivity: Date(), agentWorking: true,
                                  kind: .harness, activity: .working)
        ws.usageWarnings = Self.warnings
        let row = try Self.rowView(ws)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let controls: [NSView] = [row.closeButton, row.moreButton].filter { !$0.isHidden }
        #expect(!controls.isEmpty, "the hover controls show")
        let mark = row.usageWarningMark
        #expect(!mark.isHidden && mark.alphaValue == 1, "the badge shows on hover, not covered (alpha \(mark.alphaValue))")
        for control in controls {
            #expect(mark.frame.maxX <= control.frame.minX, "badge \(mark.frame) clear of control \(control.frame)")
        }
        #expect(mark.themedToolTip == Self.warnings.joined(separator: "\n"))
    }

    @Test func noWarningNoBadge() throws {
        let row = try Self.rowView(SidebarWorkspace(id: WorkspaceID("ws-calm"), title: "lane", lastActivity: Date(), kind: .harness))
        #expect(row.usageWarningMark.isHidden)
        #expect(row.usageWarningMark.themedToolTip == nil)
    }
}

import CmuxNextBridge
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30: "that visibility into huge-blue guys was (and is?) pretty bad i feel like we
/// can make more improvements to acpmux/cmux-next". Four uncapped deputies carried 290-330k of
/// context per call for hours and nothing in the app showed it. The workspace hover card now names
/// what its agent chat carries per call and spent in the last 24 hours, from acpmux's `usageStats`.
@MainActor @Suite struct WorkspaceHoverCardUsageTests {
    @Test func theSummaryCarriesUsageStats() throws {
        let summary: [String: Any] = [
            "sessionId": "dep-fleet", "model": "claude-opus-5-5",
            "usageStats": ["contextTokens": 312_000, "contextWindow": 1_000_000, "costUsd24h": 1_420.5,
                           "autocompactCap": NSNull(), "tokens24h": 900_000_000, "updatedAt": 1_761_800_000_000],
        ]
        let detail = try #require(AgentChatDetail.of(summary: summary))
        #expect(detail.contextTokens == 312_000)
        #expect(detail.contextWindow == 1_000_000)
        #expect(detail.costUsd24h == 1_420.5)
        // Null, negative, boolean or missing numbers are unknown, never zero.
        let unread = try #require(AgentChatDetail.of(summary: [
            "model": "m", "usageStats": ["contextTokens": NSNull(), "contextWindow": 0, "costUsd24h": -1, "updatedAt": true],
        ]))
        #expect(unread.contextTokens == nil && unread.contextWindow == nil && unread.costUsd24h == nil)
        #expect(AgentChatDetail.of(summary: ["usageStats": ["costUsd24h": true]]) == nil)
    }

    @Test func theCardNamesContextAndTheDaysCostAfterTheAgent() throws {
        var workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-usage"), machineID: CmuxNextSidebar.MachineID("local"),
                                         title: "Fleet deputy")
        workspace.agentName = "Claude"
        workspace.detail = SidebarWorkspaceDetail(model: "claude-opus-5-5", contextTokens: 312_000, contextWindow: 1_000_000,
                                                  costUsd24h: 1_420.5)
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        let kinds = card.facts.map(\.kind)
        let usage = try #require(card.facts.first { $0.kind == "usage" })
        #expect(kinds.firstIndex(of: "usage") == kinds.firstIndex(of: "agent").map { $0 + 1 })
        #expect(usage.text == "312K context · $1,421 in 24h")
        #expect(usage.icon == .contextUsage)
        #expect(usage.accessory == .ring(0.312, tone: .secondary))
    }

    @Test func aChatWithoutUsageHasNoUsageRowAndACostAloneHasNoRing() {
        #expect(WorkspaceHoverCardContent.usageFact(SidebarWorkspaceDetail(model: "m")) == nil)
        let cost = WorkspaceHoverCardContent.usageFact(SidebarWorkspaceDetail(costUsd24h: 12.4))
        #expect(cost?.text == "$12.40 in 24h")
        #expect(cost?.accessory == nil)
        let context = WorkspaceHoverCardContent.usageFact(SidebarWorkspaceDetail(contextTokens: 80_000))
        #expect(context?.text == "80K context")
        // Half away from zero, as Session Info's Usage rounds it.
        #expect(WorkspaceHoverCardContent.usageFact(SidebarWorkspaceDetail(costUsd24h: 1_420.5))?.text == "$1,421 in 24h")
    }
}

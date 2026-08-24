import Foundation
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``AgentStatus``: the single canonical presentation status shared by
/// pane borders and custom sidebars. Raw values are the wire/JSON/sidebar vocabulary, so
/// these tests lock them against accidental renames.
@Suite struct AgentStatusTests {
    @Test func rawValuesAreStableWireStrings() {
        #expect(AgentStatus.none.rawValue == "none")
        #expect(AgentStatus.running.rawValue == "running")
        #expect(AgentStatus.idle.rawValue == "idle")
        #expect(AgentStatus.needsInput.rawValue == "needsInput")
        #expect(AgentStatus.error.rawValue == "error")
    }

    @Test func codableRoundTripsEveryCase() throws {
        for status in AgentStatus.allCases {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(AgentStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test func attentionRankOrdersErrorFirst() {
        #expect(AgentStatus.error.attentionRank < AgentStatus.needsInput.attentionRank)
        #expect(AgentStatus.needsInput.attentionRank < AgentStatus.running.attentionRank)
        #expect(AgentStatus.running.attentionRank < AgentStatus.idle.attentionRank)
        #expect(AgentStatus.idle.attentionRank < AgentStatus.none.attentionRank)
    }

    @Test func tintHexMatchesTheSidebarPalette() {
        #expect(AgentStatus.error.tintHex == "#FF453A")
        #expect(AgentStatus.needsInput.tintHex == "#FF9F0A")
        #expect(AgentStatus.running.tintHex == "#0A84FF")
        #expect(AgentStatus.idle.tintHex == "#30D158")
        // No-agent is a renderer decision (pane borders draw black, sidebars use
        // their own neutral), so the palette returns nil for it.
        #expect(AgentStatus.none.tintHex == nil)
    }

    @Test func tintHexesAreStrictSixDigitHex() {
        // WorkspaceAttentionColor silently falls back to the notification-ring accent for
        // anything that is not exactly `#RRGGBB`, so a typo here would render as the wrong
        // color instead of failing.
        for status in AgentStatus.allCases {
            guard let hex = status.tintHex else { continue }
            #expect(hex.count == 7)
            #expect(hex.hasPrefix("#"))
            #expect(!hex.dropFirst().contains(where: { !$0.isHexDigit }))
        }
    }
}

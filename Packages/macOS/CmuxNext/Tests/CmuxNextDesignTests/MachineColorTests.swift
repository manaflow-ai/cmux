@testable import CmuxNextDesign
import Testing

/// A machine keeps one color everywhere: MachineColor picks AgentPresenceColor's accent for the
/// trimmed, lowercased name, the same pick the agent pane's machineColor.ts makes (its test pins
/// the same names), so the sidebar and the composer chip agree.
@MainActor @Suite struct MachineColorTests {
    @Test func matchesTheAgentPanePick() {
        let order = AgentPresenceColor.order
        #expect(order[AgentPresenceColor.index(forKey: "big-red", count: order.count)] == .purple)
        #expect(order[AgentPresenceColor.index(forKey: "air-blue", count: order.count)] == .pink)
        #expect(order[AgentPresenceColor.index(forKey: "cosmic-gray", count: order.count)] == .orange)
    }

    @Test func ignoresCaseAndSurroundingSpace() {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        #expect(MachineColor(name: " Big-Red ").rgb(tokens: tokens) == MachineColor(name: "big-red").rgb(tokens: tokens))
    }
}

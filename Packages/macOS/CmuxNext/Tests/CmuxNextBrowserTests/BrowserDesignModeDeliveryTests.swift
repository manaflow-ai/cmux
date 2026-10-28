import CoreGraphics
import Testing
@testable import CmuxNextBrowser

/// Where a design mode card goes: a variation pick is sent to the Chief's Home chat at once
/// (a304's `home.sendMessage`), an ordinary highlight waits in the Home composer, and without Home
/// the workspace's agent chat takes it.
@Suite struct BrowserDesignModeDeliveryTests {
    nonisolated static let pick = BrowserDesignModeCard(
        id: "design-1", name: "Design: figure · index.html",
        text: "Picked design variation 2: Bold hero\n\nDesign mode highlight from the cmux browser.\nPage: file:///tmp/v/index.html",
        bounds: .zero, viewportWidth: 0, pickedVariation: 2)
    nonisolated static let element = BrowserDesignModeCard(
        id: "design-2", name: "Design: button · example.com", text: "Design mode highlight from the cmux browser.",
        bounds: .zero, viewportWidth: 0)

    @Test func aPickIsSentToHomeAtOnce() {
        #expect(BrowserDesignModeDelivery(Self.pick, homeShown: true, agentChat: true)
            == .sendToHome("Picked design variation 2: Bold hero"))
    }

    @Test func anElementWaitsInTheHomeComposer() {
        #expect(BrowserDesignModeDelivery(Self.element, homeShown: true, agentChat: true) == .attachToHome)
    }

    @Test func withoutHomeTheAgentChatTakesBoth() {
        #expect(BrowserDesignModeDelivery(Self.pick, homeShown: false, agentChat: true) == .agentChat)
        #expect(BrowserDesignModeDelivery(Self.element, homeShown: false, agentChat: true) == .agentChat)
    }

    @Test func withNeitherNothingGoes() {
        #expect(BrowserDesignModeDelivery(Self.element, homeShown: false, agentChat: false) == .nowhere)
    }
}

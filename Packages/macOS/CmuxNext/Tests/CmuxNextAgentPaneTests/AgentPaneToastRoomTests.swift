import AppKit
import Testing
@testable import CmuxNextAgentPane

/// A toast never covers an agent chat (Leo, 2026-11-06: a machine toast over his queued prompt):
/// the pane gives its page the band at its foot that the toasts take.
@MainActor
struct AgentPaneToastRoomTests {
    private let pane = NSRect(x: 0, y: 0, width: 900, height: 800)

    /// A toast resting over the pane's foot takes its height, its lift and the gap.
    @Test func aToastOverThePaneFootTakesItsBand() {
        let toast = NSRect(x: 150, y: 24, width: 600, height: 60)
        #expect(AgentPaneView.toastRoom(toasts: toast, pane: pane) == 84 + AgentPaneView.toastRoomGap)
    }

    /// No toast, or toasts beside or above the pane (another pane under them): no band.
    @Test func toastsElsewhereTakeNothing() {
        #expect(AgentPaneView.toastRoom(toasts: nil, pane: pane) == 0)
        #expect(AgentPaneView.toastRoom(toasts: NSRect(x: 1000, y: 24, width: 300, height: 40), pane: pane) == 0)
        let upper = NSRect(x: 0, y: 400, width: 900, height: 400)
        #expect(AgentPaneView.toastRoom(toasts: NSRect(x: 150, y: 24, width: 600, height: 60), pane: upper) == 0)
    }

    /// A short pane keeps half its height for the chat, however tall the toasts.
    @Test func aShortPaneKeepsHalfForTheChat() {
        let short = NSRect(x: 0, y: 0, width: 900, height: 120)
        #expect(AgentPaneView.toastRoom(toasts: NSRect(x: 150, y: 24, width: 600, height: 200), pane: short) == 60)
    }
}

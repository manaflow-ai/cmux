import AppKit
@testable import CmuxNextDesign
import Testing

/// A toast's `detail` (the Stop all agents toast's refused subagents): a tooltip on the message
/// and the toast's VoiceOver help, never more text in the toast itself.
@MainActor
struct CmuxToastDetailTests {
    @Test func theDetailIsTheMessagesTooltipAndTheToastsHelp() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "1 could not be stopped", detail: "a2: refused"))
        let label = try #require(view.messageLabel)
        #expect(label.stringValue == "1 could not be stopped")
        #expect(label.themedToolTip == "a2: refused")
        #expect(view.accessibilityHelp() == "a2: refused")
    }

    @Test func noDetailMeansNoTooltip() throws {
        for detail in [nil, ""] as [String?] {
            let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Saved", detail: detail))
            #expect(view.toast.detail == nil)
            #expect(try #require(view.messageLabel).themedToolTip == nil)
        }
    }

    /// A message of three lines (the Stop all toast with a refusal and a note) keeps room above and
    /// below it on the glass.
    @Test func aThreeLineMessageKeepsRoomAboveAndBelow() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Stopped all agents: a1 and a3\n1 could not be stopped\na1 is still starting; it stops as soon as it starts.",
                                                  action: CmuxToast.Action(title: "Restart")))
        view.layoutSubtreeIfNeeded()
        let label = try #require(view.messageLabel)
        #expect(view.fittingSize.height >= label.intrinsicContentSize.height + 2 * Metrics.space2)

        // No fixed height: suites running at the same time change the shared density and
        // interface scale (a one-line toast measured 36 pt in CI, 22 pt alone).
        let one = CmuxToastView(toast: CmuxToast(id: "u", message: "Stopped all agents: a1 and a3", action: CmuxToast.Action(title: "Restart")))
        one.layoutSubtreeIfNeeded()
        #expect(one.fittingSize.height < view.fittingSize.height)
    }
}

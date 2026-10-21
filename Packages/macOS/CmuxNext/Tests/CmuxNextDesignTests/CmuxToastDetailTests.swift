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
}

@testable import CmuxNextDesign
import Testing

/// A launch must never crash because an XPC service is missing (2026-10-23). With no GUI session (a fleet
/// worker whose account is not the console user) `NSOpenPanel()` waits on its view service, gets no answer,
/// and comes back with a nil prompt and message (`String!`); the made-ahead warm-up read them into `String`
/// and the app died at launch (MadeAheadOpenPanel.swift:62, aws-m4pro-3, -4 and -6). These panels stand in
/// for `NSOpenPanel`, which this test host cannot make without that service. What the made-ahead store does with
/// such a panel (keeps none, arms no other warm-up) is in `MadeAheadPanelStoreTests`.
@MainActor
struct OpenPanelDefaultsTests {
    private final class Panel: OpenPanelLabels {
        var openPanelPrompt: String?
        var openPanelMessage: String?
        init(prompt: String?, message: String?) {
            openPanelPrompt = prompt
            openPanelMessage = message
        }
        func setOpenPanelTexts(prompt: String, message: String) {
            openPanelPrompt = prompt
            openPanelMessage = message
        }
    }

    @Test func aPanelWithNoPromptHasNoDefaults() {
        let defaults: OpenPanelDefaults? = OpenPanelDefaults(of: Panel(prompt: nil, message: nil))
        #expect(defaults == nil, "a panel with no prompt never loaded its view; keep none")
    }

    @Test func aWorkingPanelGetsItsOwnTextsBackOnReuse() throws {
        let made = Panel(prompt: "Open", message: "")
        let defaults = try #require(OpenPanelDefaults(of: made) as OpenPanelDefaults?)
        made.setOpenPanelTexts(prompt: "Attach", message: "Choose files for the chat")
        defaults.apply(to: made)
        #expect(made.openPanelPrompt == "Open")
        #expect(made.openPanelMessage == "")
    }
}

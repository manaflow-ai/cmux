import AppKit
import Testing
@testable import MessagesLabHome

/// Home's stop control (2026-10-08): while the Chief works, the compose
/// bar's round button beside the field is a stop button, and Esc or Cmd-.
/// in the field stop it too; all three call the host's one stop action.
/// While the Chief does not work, the button is the emoji button again and
/// Esc stops nothing.
@MainActor @Suite struct StopControlTests {
    @Test func whileTheChiefWorksTheButtonEscAndCommandPeriodStopIt() {
        let (_, c) = Fixture2.projection()
        var stops = 0
        c.onStop = { stops += 1 }
        c.isWorking = true
        let button = c.host.fieldChrome.emoji
        #expect(button.accessibilityLabel() == NativeStrings.stop)
        button.performClick(nil)
        #expect(stops == 1, "the stop button")
        c.escape()
        #expect(stops == 2, "Esc")
        // AppKit binds Esc and Cmd-. to cancelOperation: (NSResponder); the field's delegate takes it.
        let handled = c.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(handled && stops == 3, "Cmd-.")
    }

    @Test func whileTheChiefIsIdleTheButtonIsTheEmojiButtonAndEscStopsNothing() {
        let (_, c) = Fixture2.projection()
        var stops = 0
        c.onStop = { stops += 1 }
        c.isWorking = true
        c.isWorking = false
        #expect(c.host.fieldChrome.emoji.accessibilityLabel() == NativeStrings.emoji)
        c.escape()
        #expect(!c.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(stops == 0)
    }
}

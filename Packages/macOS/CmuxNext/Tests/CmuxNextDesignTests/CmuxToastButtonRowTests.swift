import AppKit
@testable import CmuxNextDesign
import Testing

/// The hint's buttons stand apart from its message (Leo 2026-11-21, on "Option or Shift + drag selects text
/// Don't Show Again  ×": "this styling is completely off"): Debug Settings > Toasts > Buttons draws a hairline
/// after the message (the default) or a faint fill under the quiet buttons; Plain is the look before.
@MainActor @Suite struct CmuxToastButtonRowTests {
    private static let hint = CmuxToast(id: "terminal.selectionHint", message: "Option or Shift + drag selects text")

    private static func laidOut(_ row: CmuxToastButtonRow, _ toast: CmuxToast = hint) -> CmuxToastView {
        var tuning = CmuxToastTuning()
        tuning.buttonRow = row
        let view = CmuxToastView(toast: toast, tuning: tuning)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func theDefaultDrawsAHairlineBetweenTheMessageAndTheButtons() throws {
        #expect(CmuxToastTunables.buttonRow.defaultValue == .divider)
        let view = Self.laidOut(.divider)
        let line = try #require(view.divider, "no hairline after the message")
        let message = try #require(view.messageLabel)
        let dontShow = try #require(view.neverShowButton)
        let lineFrame = line.convert(line.bounds, to: view)
        let messageFrame = message.convert(message.alignmentRect(forFrame: message.bounds), to: view)
        let buttonFrame = dontShow.convert(dontShow.bounds, to: view)
        #expect(lineFrame.minX >= messageFrame.maxX && lineFrame.maxX <= buttonFrame.minX, "the hairline is not between them")
        // The same room on both sides: to the message, and to Don't Show Again's title.
        let before = lineFrame.minX - messageFrame.maxX
        let after = buttonFrame.minX + CmuxToastButton.titlePadding - lineFrame.maxX
        #expect(abs(before - after) < 3, "the hairline is \(before) pt from the message and \(after) pt from the title")
        #expect(abs(lineFrame.midY - buttonFrame.midY) < 1, "the hairline is off the buttons' center line")
    }

    @Test func chipsRestOnAFillAndPlainIsTheOldLook() throws {
        let chips = Self.laidOut(.chips)
        #expect(chips.divider == nil)
        #expect(try #require(chips.neverShowButton).restsOnFill)
        #expect(!chips.closeButton.restsOnFill, "close keeps its bare x")
        let plain = Self.laidOut(.plain)
        #expect(plain.divider == nil)
        #expect(try #require(plain.neverShowButton).restsOnFill == false)
    }

    /// A toast with only close (an Undo-less prompt has none of these) draws no hairline before close alone.
    @Test func aToastWithOnlyCloseDrawsNoHairline() {
        let waits = CmuxToast(id: "waits", message: "Moving to Cloud", duration: CmuxToast.untilClosed)
        #expect(!waits.offersNeverShow)
        #expect(Self.laidOut(.divider, waits).divider == nil)
    }

    /// The toast is as tall with the hairline as without: it never grows a row for it.
    @Test func theHairlineKeepsTheToastsHeight() {
        #expect(abs(Self.laidOut(.divider).frame.height - Self.laidOut(.plain).frame.height) < 0.5)
    }
}

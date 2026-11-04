import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A toolbar button with keyboard focus shows the filled highlight, never a bordered ring (#34473: "use a fill
/// highlight like ChatGPT"). The pane toolbar's and the titlebar band's buttons share `TitlebarBandButton`.
@MainActor
@Suite(.closesItsWindows)
struct ToolbarFocusFillTests {
    @Test func aFocusedToolbarButtonIsFilledNotRinged() {
        let button = TitlebarBandButton(symbol: "terminal")
        button.frame = NSRect(x: 0, y: 0, width: TitlebarBandButton.side, height: TitlebarBandButton.side)
        #expect(button.focusRingType == .none)
        #expect((button.layer?.backgroundColor?.alpha ?? 0) == 0)

        // Full Keyboard Access moves focus to it (a test host may have it off, so ask the button itself).
        #expect(button.becomeFirstResponder())
        #expect(button.hover.state.focused)
        button.hover.refresh(animated: false)
        let filled = button.performWithTheme { Palette.hoverFill.cgColor }
        #expect(button.layer?.backgroundColor == filled)
        #expect((button.layer?.borderWidth ?? 0) == 0)

        #expect(button.resignFirstResponder())
        #expect(!button.hover.state.focused)
        button.hover.refresh(animated: false)
        #expect((button.layer?.backgroundColor?.alpha ?? 0) == 0)
        #expect((button.layer?.borderWidth ?? 0) == 0)
    }

    /// A button taken out of its window while focused does not keep the fill when it comes back.
    @Test func aButtonMovedOutOfItsWindowDropsTheFill() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let button = TitlebarBandButton(symbol: "globe")
        window.contentView?.addSubview(button)
        #expect(button.becomeFirstResponder())
        #expect(button.hover.state.focused)
        button.removeFromSuperview()
        window.contentView?.addSubview(button)
        #expect(!button.hover.state.focused)
    }

    /// Focus fills like hover, also in calm mode (it is not the pointer's hover); pressed still wins.
    @Test func focusTakesTheHoverFill() {
        #expect(ChromeHover.fillColor(ChromeHover.State(focused: true)) == Palette.hoverFill)
        #expect(ChromeHover.fillColor(ChromeHover.State(pressed: true, focused: true)) == Palette.pressedFill)
        #expect(ChromeHover.fillColor(ChromeHover.State(focused: true), rest: Palette.hoverFill) == ChromeHover.raisedHoverFill)
    }
}

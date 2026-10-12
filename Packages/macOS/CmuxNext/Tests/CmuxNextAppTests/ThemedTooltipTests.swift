import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo, 2026-10-12: cmux-next's tooltips were macOS's stock yellow-gray bubble ("Default" on the
/// sidebar's space tile). Controls hand their tooltip to the app's themed one instead: no AppKit
/// `toolTip`, while VoiceOver still reads the same text as the control's help.
@MainActor @Suite(.serialized) struct ThemedTooltipTests {
    @Test func controlsUseTheThemedTooltipNotAppKits() {
        let views: [(NSView, String)] = [
            (SidebarIconButton(icon: .actionClose, label: "Close Workspace"), "Close Workspace"),
            (ChromeIconButton(icon: .navPreviousMatch, label: "Previous Match", action: nil, target: nil), "Previous Match"),
            (GroupCustomSwatchView(label: "Custom Color"), "Custom Color"),
        ]
        for (view, text) in views {
            #expect(view.toolTip == nil, "\(text)")
            #expect(view.accessibilityHelp() == text, "\(text)")
        }
    }

    @Test func hoveringShowsTheThemedTooltipInTheViewsTheme() throws {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Stress Purple")),
                          input: ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF)), animated: false)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let button = NSButton(title: "", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 24)
        window.contentView?.addSubview(button)
        scope.root(try #require(window.contentView))
        button.themedToolTip = "New Tab"
        button.themedToolTipShortcut = "⌘T"
        #expect(button.toolTip == nil)
        #expect(button.accessibilityHelp() == "New Tab")

        let presenter = TooltipPresenter.shared
        let tracker = try #require(TooltipTracker.existing(for: button))
        presenter.enter(tracker)
        #expect(presenter.shown == nil, "waits the hover delay")
        presenter.fire()
        #expect(presenter.shown?.text == "New Tab")
        #expect(presenter.shown?.shortcut == "⌘T")
        let panel = presenter.panel
        #expect(panel.isVisible)
        #expect(Self.same(try #require(panel.text.textColor), scope.perform { Palette.textPrimary }))
        #expect(Self.same(try #require(panel.hint.textColor), scope.perform { Palette.textSecondary }))
        let fill = try #require(panel.contentView?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(Self.same(fill, scope.perform { Palette.elevatedBackground }))
        #expect(panel.contentView?.layer?.cornerRadius == TooltipPanel.radius)

        // Below the button, centered on it.
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        #expect(panel.frame.maxY <= anchor.minY)
        #expect(abs(panel.frame.midX - anchor.midX) <= 1)

        // A text change while shown shows the new text; clearing it hides the tooltip.
        button.themedToolTip = "New Window"
        #expect(presenter.shown?.text == "New Window")
        button.themedToolTip = nil
        #expect(presenter.shown == nil)
        #expect(!panel.isVisible)
        window.orderOut(nil)
    }

    @Test func aTooltipWithNoRoomBelowGoesAboveAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 120, height: 20)
        let low = TooltipPresenter.origin(for: size, below: NSRect(x: 980, y: 10, width: 20, height: 20), on: screen)
        #expect(low.y == 36)
        #expect(low.x == 1000 - 6 - 120)
        let high = TooltipPresenter.origin(for: size, below: NSRect(x: 100, y: 500, width: 40, height: 20), on: screen)
        #expect(high.y == 500 - 6 - 20)
        #expect(high.x == 60)
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}

import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo, 2026-10-12: cmux-next's tooltips were macOS's stock yellow-gray bubble ("Default" on the
/// sidebar's space tile). Controls hand their tooltip to the app's themed one instead: no AppKit
/// `toolTip`, while VoiceOver still reads the same text as the control's help.
@MainActor @Suite(.serialized, .closesItsWindows) struct ThemedTooltipTests {
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
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 24)
        window.contentView?.addSubview(button)
        scope.root(try #require(window.contentView))
        button.themedToolTip = "New Tab"
        button.themedToolTipShortcut = "⌘T"
        #expect(button.toolTip == nil)
        #expect(button.accessibilityHelp() == "New Tab")

        let presenter = Self.instantPresenter()
        defer {
            presenter.timing = nil
            Self.closeTooltip(presenter)
            window.close()
        }
        let tracker = try #require(TooltipTracker.whole(of: button))
        presenter.dismiss()
        // The hover delay is TooltipHoverIntentTests'; here it is zero, so the tooltip shows on enter.
        presenter.enter(tracker)
        #expect(presenter.shown?.text == "New Tab")
        #expect(presenter.shown?.shortcut == "⌘T")
        let panel = presenter.panel
        #expect(panel.isVisible)
        #expect(Self.same(try #require(panel.text.textColor), scope.perform { Palette.textPrimary }))
        #expect(Self.same(try #require(panel.hint.textColor), scope.perform { Palette.textSecondary }))
        // The shared overlay glass, drawn in the button's theme scope (Leo 2026-10-21: glass, never solid).
        #expect(panel.glass.themeScope === scope.fullStrength)
        #expect(!panel.glass.isCard)
        #expect(panel.glass.cornerRadius == TooltipPanel.radius)

        // Below the button, centered on it (the surface; the window has room for its shadow).
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        #expect(panel.frame.maxY - TooltipPanel.margin <= anchor.minY)
        #expect(abs(panel.frame.midX - anchor.midX) <= 1)

        // A text change while shown shows the new text; clearing it hides the tooltip.
        button.themedToolTip = "New Window"
        #expect(presenter.shown?.text == "New Window")
        button.themedToolTip = nil
        #expect(presenter.shown == nil)
        #expect(!panel.isVisible || panel.isFadingOut)
    }

    @Test func theDeepestTooltipUnderThePointerShowsAndRegionsWin() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let header = NSView(frame: NSRect(x: 0, y: 100, width: 300, height: 28))
        let add = NSButton(frame: NSRect(x: 270, y: 2, width: 24, height: 24))
        header.addSubview(add)
        window.contentView?.addSubview(header)
        header.themedToolTip = "This Mac"
        add.themedToolTip = "New Workspace"
        let presenter = Self.instantPresenter()
        presenter.dismiss()
        defer {
            presenter.timing = nil
            Self.closeTooltip(presenter)
            window.close()
        }

        // The pointer comes straight onto the button: whichever enter arrives last, the button's shows.
        presenter.enter(try #require(TooltipTracker.whole(of: add)))
        presenter.enter(try #require(TooltipTracker.whole(of: header)))
        #expect(presenter.shown?.text == "New Workspace")
        // Back onto the header: its own tooltip, at once.
        presenter.exit(try #require(TooltipTracker.whole(of: add)))
        #expect(presenter.shown?.text == "This Mac")

        // A region of a view (the sidebar's space tiles) wins over the view's own tooltip.
        header.setThemedToolTipRegions([(NSRect(x: 0, y: 0, width: 28, height: 28), "Default")])
        let tile = try #require(TooltipTracker.all(of: header).first { $0.region != nil })
        presenter.enter(tile)
        #expect(presenter.shown?.text == "Default")
        presenter.dismiss()
        #expect(presenter.shown == nil)
    }

    /// Review of #19902: with no hover delay, scrolling a list under a resting pointer flashed each
    /// row's tooltip as it passed. After a scroll, the row under the pointer shows its tooltip only
    /// once the scrolling stops.
    @Test func rowsPassingUnderAScrollDoNotFlashTheirTooltips() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = NSButton(frame: NSRect(x: 0, y: 100, width: 300, height: 28))
        let second = NSButton(frame: NSRect(x: 0, y: 72, width: 300, height: 28))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        first.themedToolTip = "First"
        second.themedToolTip = "Second"
        let presenter = Self.instantPresenter()
        presenter.dismiss()
        defer {
            presenter.dismiss()
            presenter.timing = nil
            Self.closeTooltip(presenter)
            window.close()
        }

        presenter.enter(try #require(TooltipTracker.whole(of: first)))
        #expect(presenter.shown?.text == "First")
        // A scroll moves the next row under the pointer.
        presenter.scrolled()
        presenter.exit(try #require(TooltipTracker.whole(of: first)))
        presenter.enter(try #require(TooltipTracker.whole(of: second)))
        #expect(presenter.shown == nil, "a row passing under the scroll flashed its tooltip")
        try await Task.sleep(for: TooltipPresenter.scrollQuiet * 3)
        #expect(presenter.shown?.text == "Second")
    }

    @Test func aTooltipWithNoRoomBelowGoesAboveAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 120, height: 20)
        let low = TooltipPresenter.origin(for: size, below: NSRect(x: 980, y: 10, width: 20, height: 20), on: screen)
        #expect(Self.near(low, NSPoint(x: 874, y: 36)), "\(low)")
        let high = TooltipPresenter.origin(for: size, below: NSRect(x: 100, y: 500, width: 40, height: 20), on: screen)
        #expect(Self.near(high, NSPoint(x: 60, y: 474)), "\(high)")
    }

    /// The shared presenter's tooltip window closes (it shows again, reopened, on the next hover).
    static func closeTooltip(_ presenter: TooltipPresenter) {
        presenter.dismiss()
        presenter.panel.close()
    }

    /// The shared presenter with no hover delay (the delay and warm group are TooltipHoverIntentTests').
    static func instantPresenter() -> TooltipPresenter {
        let presenter = TooltipPresenter.shared
        var timing = HoverIntentTiming.standard
        timing.tooltipDelay = .zero
        presenter.timing = timing
        return presenter
    }

    static func near(_ lhs: NSPoint, _ rhs: NSPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}

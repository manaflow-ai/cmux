import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-14: tooltips showed at once on every control the pointer
/// passed. They now behave as AppKit's: the first waits (about AppKit's
/// `NSInitialToolTipDelay`), a neighbor's then shows at once while the group
/// is warm, and half a second away cools it again. A control whose own label
/// already names it shows none (#20375's rule).
@MainActor @Suite(.serialized) struct TooltipHoverIntentTests {
    /// Five icon buttons in a row, like a toolbar, on a presenter that runs on `clock`.
    private static func toolbar(clock: ManualClock) -> (NSWindow, [ChromeIconButton], TooltipPresenter) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let labels = ["Back", "Forward", "Reload", "Share", "Downloads"]
        let buttons = labels.enumerated().map { index, label in
            let button = ChromeIconButton(icon: .navPreviousMatch, label: label, action: nil, target: nil)
            button.frame = NSRect(x: 10 + CGFloat(index) * 30, y: 18, width: 24, height: 24)
            window.contentView?.addSubview(button)
            return button
        }
        window.orderFrontRegardless()
        return (window, buttons, TooltipPresenter(clock: clock))
    }

    private static func tracker(_ view: NSView) throws -> TooltipTracker {
        try #require(TooltipTracker.whole(of: view))
    }

    /// Lets a deadline the clock reached land on the main actor.
    private static func settle(until done: (() -> Bool)? = nil) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<(done == nil ? 3 : 500) where done?() != true { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theFirstTooltipWaitsThenNeighborsShowAtOnceUntilTheGroupCools() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        // The first tooltip waits the initial delay (800 ms).
        presenter.enter(try Self.tracker(buttons[0]))
        #expect(presenter.shown == nil, "the first tooltip showed with no delay")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        try await Self.settle()
        #expect(presenter.shown == nil, "the first tooltip showed before the delay")
        clock.advance(by: .milliseconds(400))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Back")

        // Warm: the neighbor's shows at once.
        presenter.exit(try Self.tracker(buttons[0]))
        presenter.enter(try Self.tracker(buttons[1]))
        #expect(presenter.shown?.text == "Forward", "a neighbor's tooltip waited while the group was warm")
        // Off the toolbar for a moment (less than the warm time), then onto another: still at once.
        presenter.exit(try Self.tracker(buttons[1]))
        #expect(presenter.shown == nil)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(200))
        try await Self.settle()
        presenter.enter(try Self.tracker(buttons[2]))
        #expect(presenter.shown?.text == "Reload", "a tooltip within the warm time waited")

        // Away past the warm time (500 ms): the next one waits the full delay again.
        presenter.exit(try Self.tracker(buttons[2]))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(600))
        try await Self.settle()
        presenter.enter(try Self.tracker(buttons[3]))
        #expect(presenter.shown == nil, "the group stayed warm past its cool-down")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(900))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Share")
    }

    @Test func aFastSweepAcrossTheToolbarShowsNoTooltip() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        var shown: [String] = []
        // 30 pt per button at 500 pt/s: 60 ms on each.
        for button in buttons {
            presenter.enter(try Self.tracker(button))
            if let text = presenter.shown?.text { shown.append(text) }
            for _ in 0..<30 {
                clock.advance(by: .milliseconds(2))
                await Task.yield()
            }
            if let text = presenter.shown?.text, shown.last != text { shown.append(text) }
            presenter.exit(try Self.tracker(button))
        }
        clock.advance(by: .milliseconds(1_500))
        try await Self.settle()
        if let text = presenter.shown?.text { shown.append(text) }
        #expect(shown.isEmpty, "the sweep showed \(shown)")
    }

    @Test func aControlWhoseLabelNamesItShowsNoTooltip() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        let labeled = NSButton(title: "Reload", target: nil, action: nil)
        labeled.frame = NSRect(x: 160, y: 18, width: 80, height: 24)
        window.contentView?.addSubview(labeled)
        labeled.themedToolTip = "Reload"
        presenter.enter(try Self.tracker(labeled))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(2_000))
        try await Self.settle()
        #expect(presenter.shown == nil, "a button titled Reload showed the tooltip Reload")
        // An icon-only neighbor still shows its own.
        presenter.exit(try Self.tracker(labeled))
        presenter.enter(try Self.tracker(buttons[0]))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(2_000))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Back")
    }
}

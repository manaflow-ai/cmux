import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-10-14: tooltips showed at once on every control the pointer
/// passed. They now behave as AppKit's: the first waits (about AppKit's
/// `NSInitialToolTipDelay`), a neighbor's then shows at once while the group
/// is warm, and half a second away cools it again. A control whose own label
/// already names it shows none (#20375's rule).
@MainActor @Suite(.serialized, .closesItsWindows) struct TooltipHoverIntentTests {
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
        let presenter = TooltipPresenter(clock: clock)
        // The standard timing, whatever a developer's tunables say.
        presenter.timing = .standard
        return (window, buttons, presenter)
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
            window.closeAfterTest()
        }
        // The first tooltip waits the initial delay (250 ms).
        presenter.enter(try Self.tracker(buttons[0]))
        #expect(presenter.shown == nil, "the first tooltip showed with no delay")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(150))
        try await Self.settle()
        #expect(presenter.shown == nil, "the first tooltip showed before the delay")
        clock.advance(by: .milliseconds(100))
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
        clock.advance(by: .milliseconds(600))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Share")
    }

    @Test func aFastSweepAcrossTheToolbarShowsNoTooltip() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.closeAfterTest()
        }
        var shown: [String] = []
        // 30 pt per button at 500 pt/s: 60 ms on each.
        for button in buttons {
            presenter.enter(try Self.tracker(button))
            if let text = presenter.shown?.text { shown.append(text) }
            try await clock.waitForSleeper()
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
            window.closeAfterTest()
        }
        let labeled = NSButton(title: "Reload", target: nil, action: nil)
        labeled.frame = NSRect(x: 160, y: 18, width: 80, height: 24)
        window.contentView?.addSubview(labeled)
        labeled.themedToolTip = "Reload"
        presenter.enter(try Self.tracker(labeled))
        #expect(presenter.shown == nil, "a button titled Reload showed the tooltip Reload")
        // Past the delay, before a shown tooltip's recheck (500 ms) could put it away.
        clock.advance(by: .milliseconds(600))
        try await Self.settle()
        #expect(presenter.shown == nil, "a button titled Reload showed the tooltip Reload after the delay")
        // An icon-only neighbor still shows its own.
        presenter.exit(try Self.tracker(labeled))
        presenter.enter(try Self.tracker(buttons[0]))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(2_000))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Back")
    }

    /// a1315's cut 2: a control that shows its own text gets no tooltip, even one that says more than its label
    /// (a titled button, a label). A shortcut still shows, as a page's `data-tooltip-shortcut` does.
    @Test func aControlThatShowsItsOwnTextShowsNoTooltip() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.closeAfterTest()
        }
        let button = NSButton(title: "Reload", target: nil, action: nil)
        button.frame = NSRect(x: 160, y: 18, width: 80, height: 24)
        window.contentView?.addSubview(button)
        button.themedToolTip = "Run the script again from its saved files"
        let label = ChromeLabel(labelWithString: "main")
        label.frame = NSRect(x: 250, y: 18, width: 60, height: 20)
        window.contentView?.addSubview(label)
        label.themedToolTip = "~/fun/cmux on main"
        // The steps below do show an icon-only control's tooltip, so they can see one; then the group cools.
        presenter.enter(try Self.tracker(buttons[0]))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(2_000))
        try await Self.settle(until: { presenter.shown?.text == "Back" })
        #expect(presenter.shown?.text == "Back")
        presenter.exit(try Self.tracker(buttons[0]))
        presenter.dismiss()
        if (try? await clock.waitForSleeper()) != nil { clock.advance(by: .milliseconds(2_000)) }
        try await Self.settle(until: { presenter.shown == nil })
        for view in [button, label] as [NSView] {
            presenter.enter(try Self.tracker(view))
            // A tooltip for it would start the hover delay: run any delay out, past the first delay, then look. With
            // none, nothing waits on the clock (waitForSleeper gives up after its bound).
            if (try? await clock.waitForSleeper()) != nil {
                clock.advance(by: .milliseconds(2_000))
                try await Self.settle(until: { presenter.shown != nil })
            }
            try await Self.settle()
            #expect(presenter.shown == nil, "\(type(of: view)) showing its own text showed \(presenter.shown?.text ?? "")")
            presenter.exit(try Self.tracker(view))
        }
        // A titled control's shortcut is no text it shows: that tooltip stays.
        button.themedToolTip = "Reload"
        button.themedToolTipShortcut = "⌘R"
        presenter.enter(try Self.tracker(button))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(2_000))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.shortcut == "⌘R")
    }

    /// A titled button inside a view with its own tooltip: the button's label
    /// names it, so nothing shows, not the container's tooltip instead.
    @Test func aLabeledControlInsideATooltipViewShowsNeither() async throws {
        let clock = ManualClock()
        let (window, _, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            window.closeAfterTest()
        }
        let container = NSView(frame: NSRect(x: 160, y: 10, width: 120, height: 40))
        window.contentView?.addSubview(container)
        container.themedToolTip = "Page actions"
        let labeled = NSButton(title: "Reload", target: nil, action: nil)
        labeled.frame = NSRect(x: 10, y: 8, width: 80, height: 24)
        container.addSubview(labeled)
        labeled.themedToolTip = "Reload"
        presenter.enter(try Self.tracker(container))
        presenter.enter(try Self.tracker(labeled))
        // Past any delay (the standard and AppKit's), before a shown tooltip's recheck could hide it;
        // in steps, so a wait armed on enter is asleep before the clock passes it.
        for _ in 0..<10 {
            try await Self.settle()
            clock.advance(by: .milliseconds(100))
        }
        try await Self.settle()
        #expect(presenter.shown == nil, "hovering the button titled Reload showed \(presenter.shown?.text ?? "")")
    }

    /// AppKit can report a view's visible rect past its bounds (the sidebar's bottom Default item,
    /// whose area then covered the whole sidebar), so the pointer "entered" a deeper tooltip far
    /// from it: the sidebar toggle showed "Default", by the window's bottom edge. Only a tooltip
    /// whose view is under the pointer competes.
    @Test func aDeeperTooltipAwayFromThePointerDoesNotWin() async throws {
        let clock = ManualClock()
        let (window, buttons, presenter) = Self.toolbar(clock: clock)
        defer {
            presenter.dismiss()
            PointerHover.setDebugPointer(nil, in: window)
            window.closeAfterTest()
        }
        let outer = NSView(frame: NSRect(x: 160, y: 0, width: 140, height: 60))
        let inner = NSView(frame: NSRect(x: 10, y: 5, width: 120, height: 50))
        let deep = ChromeIconButton(icon: .navPreviousMatch, label: "Default", action: nil, target: nil)
        deep.frame = NSRect(x: 90, y: 13, width: 24, height: 24)
        window.contentView?.addSubview(outer)
        outer.addSubview(inner)
        inner.addSubview(deep)
        let back = buttons[0]
        PointerHover.setDebugPointer(back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil), in: window)
        presenter.enter(try Self.tracker(deep))
        presenter.enter(try Self.tracker(back))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        try await Self.settle(until: { presenter.shown != nil })
        #expect(presenter.shown?.text == "Back", "the pointer over Back showed \(presenter.shown?.text ?? "nothing")")
    }
}

import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-10-22 (ask-a8b97f1201): "the tab unread + simultaneous ongoing thing feels weird idk if there is a way
/// to combine + the spacing is off". A busy tab with unread output draws one mark in the status slot, not the
/// unread dot with the spinner squeezed in beside it; when the work ends the dot takes that same slot, so the
/// title's end never moves.
@MainActor @Suite(.serialized) struct TabBusyUnreadMarkTests {
    private static let id = TabID("busy-unread")

    private static func item(busy: Bool, unread: Bool = true) -> TabItem {
        var item = TabItem(id: id, title: "A long enough page title to clip", icon: .icon(.browser), isUnread: unread, isBusy: busy)
        if busy { item.indicator = .busy(progress: nil) }
        return item
    }

    private static func cell(busy: Bool, look: TabBusyUnreadMark? = nil) -> TabCell {
        let cell = TabCell(item: item(busy: busy))
        if let look {
            var metrics = cell.metrics
            metrics.busyUnreadMark = look
            cell.metrics = metrics
        }
        cell.scale = 2
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.layoutLayers()
        return cell
    }

    private static func shows(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return !layer.isHidden && layer.opacity > 0 && layer.superlayer != nil
    }

    /// The marks a person sees side by side: the dot and the spinner count as two unless one sits inside the other.
    private static func separateMarks(_ cell: TabCell) -> Int {
        let dot = shows(cell.badgeLayer) ? cell.badgeLayer?.frame : nil
        let spinner = shows(cell.spinnerLayer?.layer) ? cell.spinnerLayer?.frame : nil
        switch (dot, spinner) {
        case let (dot?, spinner?): return spinner.contains(dot) ? 1 : 2
        case (nil, nil): return 0
        default: return 1
        }
    }

    @Test func theDefaultCombinesTheUnreadDotAndTheSpinnerIntoOneMark() {
        #expect(TabTunables.busyUnreadMark.defaultValue != .pair, "the default still draws the dot and the spinner side by side")
        let cell = Self.cell(busy: true)
        #expect(Self.separateMarks(cell) == 1, "a busy unread tab draws \(Self.separateMarks(cell)) marks")
    }

    @Test(arguments: TabBusyUnreadMark.allCases.filter { $0 != .pair })
    func everyCombinedLookDrawsOneMarkInTheStatusSlot(look: TabBusyUnreadMark) throws {
        let cell = Self.cell(busy: true, look: look)
        #expect(Self.separateMarks(cell) == 1, "\(look): \(Self.separateMarks(cell)) marks")
        let spinner = try #require(cell.spinnerLayer?.frame, "\(look): no busy indicator")
        // The status slot (the x's) is where an idle unread tab draws its dot.
        let idle = try #require(Self.cell(busy: false, look: look).badgeLayer?.frame, "\(look): an idle unread tab draws no dot")
        #expect(abs(spinner.midX - idle.midX) <= 0.5, "\(look): the mark is at \(spinner.midX), an idle unread tab's dot at \(idle.midX)")
    }

    @Test(arguments: TabBusyUnreadMark.allCases.filter { $0 != .pair })
    func theTitleEndHoldsWhenTheWorkEnds(look: TabBusyUnreadMark) throws {
        let cell = Self.cell(busy: true, look: look)
        let busyTitleEnd = try #require(cell.titleFade.geometry?.visibleWidth)
        let busyMark = try #require(cell.spinnerLayer?.frame)
        cell.update(item: Self.item(busy: false))
        cell.layoutLayers()
        let dot = try #require(cell.badgeLayer?.frame, "\(look): no unread dot once the work ended")
        #expect(abs(dot.midX - busyMark.midX) <= 0.5, "\(look): the dot lands at \(dot.midX), the mark was at \(busyMark.midX)")
        let idleTitleEnd = try #require(cell.titleFade.geometry?.visibleWidth)
        #expect(idleTitleEnd == busyTitleEnd, "\(look): the title's visible width moved from \(busyTitleEnd) to \(idleTitleEnd)")
        // A spinner still fading out does so under the dot, never beside it.
        if let leaving = cell.spinnerLayer?.frame {
            #expect(abs(leaving.midX - dot.midX) <= 0.5, "\(look): the leaving spinner is at \(leaving.midX), the dot at \(dot.midX)")
        }
    }

    /// The same hand-over with the Debug loading animation at each prototype: the title holds through every exit.
    @Test(arguments: TabLoadingAnimation.allCases)
    func theTitleEndHoldsUnderEveryLoadingAnimation(animation: TabLoadingAnimation) throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(TabTunables.all)
        defer { store.set(TabTunables.loadingAnimation.key, nil) }
        try #require(store.set(TabTunables.loadingAnimation.key, .choice(animation.rawValue)) == .choice(animation.rawValue))
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cell = Self.cell(busy: true, look: .spinner)
        let busyTitleEnd = try #require(cell.titleFade.geometry?.visibleWidth)
        cell.update(item: Self.item(busy: false))
        cell.layoutLayers()
        #expect(cell.titleFade.geometry?.visibleWidth == busyTitleEnd, "\(animation): the title's visible width moved")
    }

    @Test func thePairLookKeepsTheOldTwoMarks() {
        let cell = Self.cell(busy: true, look: .pair)
        #expect(Self.separateMarks(cell) == 2)
    }

    @Test func aStatusStillShowsBesideTheSpinner() {
        var item = Self.item(busy: true)
        item.status = .needsInput
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.layoutLayers()
        // The status draws as the dot, or as a status icon set's glyph.
        #expect(Self.shows(cell.badgeLayer) || Self.shows(cell.statusGlyphLayer?.layer), "a needs-input mark gave way to the spinner")
        #expect(Self.shows(cell.spinnerLayer?.layer), "the spinner gave way to the needs-input mark")
    }

    /// Review F1 of #45479: switching the Debug look redraws the tabs already on screen, with no other update. The
    /// strip's token observation reads the look, so the busy unread tab turns into the old two marks once the main
    /// actor runs the observation's redraw, and back to one mark when the override clears.
    @Test func switchingTheDebugLookRedrawsALiveStrip() async throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(TabTunables.all)
        let key = TabTunables.busyUnreadMark.key
        defer { store.set(key, nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let tabs = [TabItem(id: TabID("quiet"), title: "zsh"), Self.item(busy: true)]
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("quiet")))
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 520, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[Self.id])
        // What the busy unread tab shows: the dot, the spinner, and how many marks they make side by side.
        func seen() -> String {
            "dot \(Self.shows(cell.badgeLayer)), spinner \(Self.shows(cell.spinnerLayer?.layer)), marks \(Self.separateMarks(cell))"
        }
        // The marks once the strip settles. The observation's redraw is a main-actor job: the test suspends (it
        // runs as a main-queue job itself, so pumping the run loop from inside it would never run that job).
        func marks(after change: () -> Void) async throws -> Int {
            let start = Self.separateMarks(cell)
            change()
            var now = start
            for _ in 0 ..< 40 where now == start {
                try await Task.sleep(for: .milliseconds(10))
                strip.layoutSubtreeIfNeeded()
                now = Self.separateMarks(cell)
            }
            return now
        }
        try #require(Self.shows(cell.spinnerLayer?.layer), "the busy tab in the strip shows no spinner: \(seen())")
        #expect(Self.separateMarks(cell) == 1, "the default look: \(seen())")
        let paired = try await marks { store.set(key, .choice(TabBusyUnreadMark.pair.rawValue)) }
        #expect(paired == 2, "the open tab kept one mark after the look became the pair: \(seen())")
        let restored = try await marks { store.set(key, nil) }
        #expect(restored == 1, "the open tab kept two marks after the look went back to the default: \(seen())")
    }
}

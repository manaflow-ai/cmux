import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

/// The tab strip and the saved groups bar scroll by translation (feature
/// `tabStripScrollFrames`), as Chrome's tab strip scrolls a layer-backed `views::ScrollView`
/// (ui/views/controls/scroll_view.cc): a frame's wheel and trackpad events reach the strip at most twice
/// per frame on p04-input-030's `FrameInputCoalescer`, summed per phase, and move one layer. The cells are
/// laid out again (`applyFrames`) only when the tabs in view change, at the gesture's end and before a
/// press; a click after a scroll hits the tab under the pointer; the scroll math is unchanged.
@MainActor @Suite(.serialized) struct TabStripScrollTests {
    @MainActor final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let frames = PointerFrameTestRig()

        /// 20 Scroll-mode tabs (about 140 pt each) in a 1000 pt strip, frame-aligned wheels unless `frameInput` is false.
        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            DesignSettings.shared.tabOverflow = .scroll
            model = TabStripModel(tabs: (0..<20).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
            strip = TabStripView.testing(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 1000, height: TabStripView.preferredHeight)
            window.isReleasedWhenClosed = false
            window.contentView = strip
            strip.applyTokens(animated: false)
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
            if frameInput { strip.scrollFrameInput = frames.coalescers }
            model.intentHandler = { [unowned self] intent in
                if case .select(let id) = intent { model.selectedID = id }
            }
        }

        /// Rests the strip at an offset whose two edges are more than `room` points from every tab's edge
        /// (scrolling either way by up to `room` changes no tab in view); nil when the layout has none.
        func restAwayFromTabEdges(room: CGFloat) -> CGFloat? {
            let edges = strip.result.slots.flatMap { [$0.x, $0.maxX] }
            let width = strip.viewportWidth
            let maxOffset = TabScrollMath.maxOffset(contentWidth: strip.result.contentWidth, viewportWidth: width)
            func clear(_ edge: CGFloat) -> Bool { !edges.contains { $0 >= edge - room - 1 && $0 <= edge + room + 1 } }
            guard let offset = stride(from: maxOffset / 2, to: maxOffset, by: 1).first(where: { clear($0) && clear($0 + width) }) else { return nil }
            strip.restoreScrollOffset(offset)
            return strip.scrollOffset
        }

        /// The strip's backing scale, as `cellFrame` rounds with it.
        var scale: CGFloat { strip.window?.backingScaleFactor ?? 2 }

        /// The tab whose center shows nearest the middle of the strip.
        func middleTab() -> Int {
            let middle = strip.scrollOffset + strip.viewportWidth / 2
            let slots = strip.result.slots
            return slots.indices.min { abs(slots[$0].x + slots[$0].width / 2 - middle) < abs(slots[$1].x + slots[$1].width / 2 - middle) } ?? 0
        }

        func close() {
            frames.close()
            window.close()
            DesignSettings.shared.tabOverflow = .shrink
        }
    }

    /// A trackpad scroll of `dx` points (positive moves the tabs right, toward the strip's start).
    static func trackpad(dx: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) // a trackpad's point deltas
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try #require(NSEvent(cgEvent: cg))
    }

    /// One wheel delivery as the frame wheel hands it to the strip (exact deltas, which a `CGEvent` cannot carry).
    static func delivery(dx: CGFloat, phase: InputScrollPhase, isPrecise: Bool = true) -> PointerFrameWheel.Scroll {
        PointerFrameWheel.Scroll(delta: CGVector(dx: dx, dy: 0), isPrecise: isPrecise, phase: phase, location: .zero)
    }

    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    // MARK: The strip

    /// The acceptance case: a gesture's first event scrolls at once (one translation), the next 20 events
    /// of the frame wait, and the frame moves the layer once for all 20. No layout runs, the offset is the
    /// clamped sum of the deltas, and every cell shows where its slot is at that offset.
    @Test func twentyWheelEventsInAFrameSetOneTranslationAndLayNothingOut() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        try #require(strip.result.isOverflowing, "20 tabs fit in 1000 pt, nothing scrolls")
        let start = try #require(harness.restAwayFromTabEdges(room: 22))
        let frames = strip.rowPasses.frames
        let sets = strip.scroller.translationSets

        let began = try Self.trackpad(dx: 1, phase: .began)
        strip.scrollWheel(with: began)
        #expect(strip.scroller.translationSets == sets + 1, "the gesture's first event waited for the frame")
        var sum = began.scrollingDeltaX
        for _ in 0..<20 {
            let event = try Self.trackpad(dx: 1, phase: .changed)
            sum += event.scrollingDeltaX
            strip.scrollWheel(with: event)
        }
        #expect(strip.scroller.hasPending, "the frame's later events applied before the frame")
        #expect(strip.scroller.translationSets == sets + 1)
        harness.frames.frame()

        #expect(!strip.scroller.hasPending)
        #expect(strip.scroller.translationSets == sets + 2, "20 events in a frame set \(strip.scroller.translationSets - sets - 1) translations")
        #expect(strip.rowPasses.frames == frames, "the scroll laid the strip out \(strip.rowPasses.frames - frames) times")
        let expected = TabScrollMath.clamp(start - sum, contentWidth: strip.result.contentWidth, viewportWidth: strip.viewportWidth)
        #expect(abs(strip.scrollOffset - expected) < 0.01, "offset \(strip.scrollOffset), the clamped sum gives \(expected)")
        // The translation is whole device pixels: within half a pixel of the scroll.
        let pixel = 1 / harness.scale
        #expect(abs(strip.scroller.translation - (strip.scrollOffset - start)) <= pixel / 2 + 0.001)
        #expect(abs(strip.scrollingLayer.bounds.origin.x - (strip.scrollMapping.band + strip.scroller.translation)) < 0.01)
        for (id, cell) in strip.cells {
            let slot = try #require(strip.result.slot(id))
            let shown = strip.scroller.shownFrame(cell.layer)
            #expect(abs(shown.minX - (slot.x - strip.scrollOffset)) <= pixel + 0.01, "\(id.rawValue) shows at \(shown.minX), its slot at \(slot.x - strip.scrollOffset)")
        }
    }

    /// A trackpad's fractional deltas move the cells by whole device pixels, as `cellFrame` places them:
    /// no title draws between pixels while the fingers move.
    @Test func fractionalDeltasTranslateByWholePixels() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        _ = try #require(harness.restAwayFromTabEdges(room: 22))
        let frames = strip.rowPasses.frames
        let scale = harness.scale
        func isWholePixels(_ value: CGFloat) -> Bool { abs(value * scale - (value * scale).rounded()) < 0.001 }
        strip.scroller.scroll(Self.delivery(dx: 0.37, phase: .began))
        for _ in 0..<5 {
            strip.scroller.scroll(Self.delivery(dx: 0.41, phase: .changed))
            #expect(isWholePixels(strip.scroller.translation), "translation \(strip.scroller.translation) at scale \(scale)")
            #expect(isWholePixels(strip.scrollingLayer.bounds.origin.x), "bounds origin \(strip.scrollingLayer.bounds.origin.x) at scale \(scale)")
        }
        #expect(strip.scroller.translation != 0, "2.42 pt of scroll showed nothing")
        #expect(strip.rowPasses.frames == frames, "the scroll laid the strip out")
        for cell in strip.cells.values {
            #expect(isWholePixels(strip.scroller.shownFrame(cell.layer).minX), "a cell shows at \(strip.scroller.shownFrame(cell.layer).minX)")
        }
    }

    /// A mouse wheel's notch has no gesture end: the tabs' accessibility frames follow its translation at once.
    @Test func aWheelNotchMovesTheAccessibilityFramesWithTheTabs() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        _ = try #require(harness.restAwayFromTabEdges(room: 30))
        for _ in 0..<2 { strip.scroller.scroll(Self.delivery(dx: 1, phase: .none, isPrecise: false)) }
        try #require(strip.scroller.translation != 0, "the notches laid the strip out: nothing to follow")
        let cell = try #require(strip.cells[TabID("t\(harness.middleTab())")])
        let shown = strip.tabsClip.convert(strip.scroller.shownFrame(cell.layer), to: strip)
        try #require(shown != strip.tabsClip.convert(cell.frame, to: strip))
        #expect(cell.accessibility.accessibilityFrameInParentSpace() == shown,
                "the tab's accessibility frame \(cell.accessibility.accessibilityFrameInParentSpace()) is not where it shows, \(shown)")
    }

    /// A gesture whose end never arrived (the tabs stopped overflowing, the window changed) does not keep
    /// the next gesture from dismissing a shown card.
    @Test func aGestureWithALostEndStillLetsTheNextOneDismissTheCard() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        let coordinator = HoverCardCoordinator(clock: ManualClock())
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.pointerLocation = { .zero }
        strip.hoverCards = coordinator
        defer { coordinator.dismiss(.action) }
        _ = try #require(harness.restAwayFromTabEdges(room: 22))

        strip.scrollWheel(with: try Self.trackpad(dx: 1, phase: .began))
        strip.scrollWheel(with: try Self.trackpad(dx: 1, phase: .changed))
        harness.frames.frame()
        // Its .ended is lost: the next gesture starts.
        _ = strip.showHoverCard(for: TabID("t\(harness.middleTab())"))
        try #require(coordinator.machine.shownTarget != nil, "no card to dismiss")
        strip.scrollWheel(with: try Self.trackpad(dx: 1, phase: .began))
        #expect(coordinator.machine.activeTarget == nil, "the new gesture left the card on screen")
    }

    /// A press after a translated scroll lands the frame's pending deltas and lays the cells out where they
    /// show, and the click selects the tab under the pointer. The hit test agrees before the layout too, at a
    /// point the cell's laid-out frame does not cover (the translation moved the tab left over it, so the
    /// laid-out frames alone put it in the tab before).
    @Test func aClickAfterAScrollHitsTheTabUnderThePointer() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        _ = try #require(harness.restAwayFromTabEdges(room: 22))
        strip.scrollWheel(with: try Self.trackpad(dx: -1, phase: .began))
        for _ in 0..<15 { strip.scrollWheel(with: try Self.trackpad(dx: -1, phase: .changed)) }
        harness.frames.frame()
        for _ in 0..<5 { strip.scrollWheel(with: try Self.trackpad(dx: -1, phase: .changed)) }
        try #require(strip.scroller.translation > 8, "the scroll laid the strip out, or moved it \(strip.scroller.translation) pt")
        let frames = strip.rowPasses.frames

        let index = harness.middleTab()
        let id = TabID("t\(index)")
        let cell = try #require(strip.cells[id])
        let shown = strip.scroller.shownFrame(cell.layer)
        // On the tab's leading part, where it shows, and off its laid-out frame.
        let inClip = CGPoint(x: shown.minX + 6, y: strip.tabsClip.bounds.midY)
        try #require(inClip.x < cell.frame.minX, "the laid-out frame covers the point too: the test tells nothing apart")
        if let before = strip.cells[TabID("t\(index - 1)")] {
            try #require(strip.scroller.shownFrame(before.layer).maxX <= inClip.x, "the tab before shows over the point")
        }
        let point = strip.convert(strip.convert(inClip, from: strip.tabsClip), to: nil)
        #expect(strip.tabID(at: strip.convert(point, from: nil)) == id, "the hit test missed the translation")
        strip.mouseDown(with: try Self.mouse(.leftMouseDown, at: point, in: harness.window))
        #expect(!strip.scroller.hasPending, "the press left scroll for a later frame")
        #expect(strip.scroller.translation == 0, "the press did not lay the cells out where they show")
        #expect(strip.rowPasses.frames > frames)
        strip.mouseUp(with: try Self.mouse(.leftMouseUp, at: point, in: harness.window))
        #expect(harness.model.selectedID == id, "the click selected \(String(describing: harness.model.selectedID)), not \(id.rawValue)")
        let landed = try #require(strip.cells[id])
        let slot = try #require(strip.result.slot(id))
        #expect(abs(landed.frame.minX - (slot.x - strip.scrollOffset)) <= 0.5)
    }

    /// The fingers lifting ends the gesture: the cells are laid out once where they show.
    @Test func theGesturesEndLaysTheCellsOutOnce() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        _ = try #require(harness.restAwayFromTabEdges(room: 22))
        strip.scrollWheel(with: try Self.trackpad(dx: 2, phase: .began))
        strip.scrollWheel(with: try Self.trackpad(dx: 2, phase: .changed))
        harness.frames.frame()
        try #require(strip.scroller.translation != 0)
        let frames = strip.rowPasses.frames
        strip.scrollWheel(with: try Self.trackpad(dx: 0, phase: .ended))
        harness.frames.frame()
        #expect(strip.rowPasses.frames == frames + 1, "the gesture's end laid out \(strip.rowPasses.frames - frames) times")
        #expect(strip.scroller.translation == 0)
        #expect(strip.scrollingLayer.bounds.origin.x == strip.scrollMapping.band)
    }

    /// A scroll that brings another tab into view lays the strip out (once), with no translation.
    @Test func aScrollThatChangesTheTabsInViewLaysOut() throws {
        let harness = Harness()
        defer { harness.close() }
        let strip = harness.strip
        _ = try #require(harness.restAwayFromTabEdges(room: 22))
        let frames = strip.rowPasses.frames
        let sets = strip.scroller.translationSets
        strip.scrollWheel(with: try Self.trackpad(dx: 300, phase: .began))
        #expect(strip.rowPasses.frames == frames + 1)
        #expect(strip.scroller.translationSets == sets)
        #expect(strip.scroller.translation == 0)
    }

    /// Feature off (no frame input): each event scrolls and lays out at once, as before.
    @Test func withoutFrameInputEachEventLaysOut() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        let strip = harness.strip
        let start = try #require(harness.restAwayFromTabEdges(room: 22))
        let frames = strip.rowPasses.frames
        for _ in 0..<3 { strip.scrollWheel(with: try Self.trackpad(dx: 1, phase: .changed)) }
        #expect(strip.rowPasses.frames == frames + 3)
        #expect(strip.scroller.translationSets == 0)
        #expect(strip.scrollOffset < start)
    }

    // MARK: The saved groups bar

    /// The bar moves its content layer once for a frame's 20 events, and writes its chips' accessibility
    /// frames at the gesture's end, not per frame.
    @Test func theSavedGroupsBarMovesOneLayerOncePerFrame() throws {
        _ = NSApplication.shared
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        let ids = (0..<12).map { TabGroupID("saved\($0)") }
        let model = SavedGroupsBarModel(groups: ids.map { SavedTabGroupItem(id: $0, name: "Group \($0)", colorToken: .blue, tabCount: 2) })
        let bar = SavedGroupsBarView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: SavedGroupsBarView.preferredHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = bar
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: SavedGroupsBarView.preferredHeight)
        bar.layoutSubtreeIfNeeded()
        bar.scrollFrameInput = frames.coalescers
        try #require(bar.maxScrollOffset > 30, "12 chips fit in 300 pt")
        let applies = bar.scrollApplies

        bar.scrollWheel(with: try Self.trackpad(dx: -1, phase: .began))
        #expect(bar.scrollApplies == applies + 1, "the gesture's first event waited for the frame")
        for _ in 0..<20 { bar.scrollWheel(with: try Self.trackpad(dx: -1, phase: .changed)) }
        #expect(bar.scrollApplies == applies + 1)
        frames.frame()
        #expect(bar.scrollApplies == applies + 2, "20 events in a frame moved the layer \(bar.scrollApplies - applies - 1) times")
        let offset = bar.scrollOffset
        #expect(offset > 0)

        let chip = try #require(bar.chips[ids[1]])
        #expect(chip.accessibility.accessibilityFrameInParentSpace() == chip.frame, "accessibility frames were written per scroll frame")
        bar.scrollWheel(with: try Self.trackpad(dx: 0, phase: .ended))
        #expect(chip.accessibility.accessibilityFrameInParentSpace() == chip.frame.offsetBy(dx: -offset, dy: 0))
    }
}

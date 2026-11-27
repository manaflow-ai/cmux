import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing
import CmuxNextTestSupport

/// Leo 2026-10-12 (cx-ag5.11), the tab strip every pane kind shows
/// (`PaneContentView.stripView`), driven with real mouse events:
/// - Only the + button opens a new tab: a double-click on empty strip space
///   does nothing.
/// - Clicking close buttons again and again under a still pointer closes
///   exactly one tab per click: the tab under the pointer, whose close
///   button is there because the tabs keep their widths until the pointer
///   leaves the strip (Chrome's closing mode). A click that comes before the
///   strip caught up with the last close still closes the next tab, never the
///   closed one again and never selects instead.
@MainActor @Suite(.closesItsWindows, .serialized) struct TabStripRapidCloseTests {
    final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []
        private(set) var closed: [TabID] = []

        init(count: Int) {
            model = TabStripModel(tabs: (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            window.contentView = strip
            // Mouse events reach the strip only in a window that was ordered in.
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                intents.append(intent)
                // As the pane does (`PaneController.close`): the tab leaves the model at once,
                // and the strip catches up on its next model sync.
                if case .close(let id, _) = intent {
                    closed.append(id)
                    model.tabs.removeAll { $0.id == id }
                }
            }
        }

        /// The center of tab `id`'s close button, in window coordinates, with the pointer over the tab.
        func closeButton(_ id: TabID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            TabStripDebug.pointerMoved(in: strip, to: strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip))
            let rect = try #require(cell.closeButtonRect, "tab \(id.rawValue) shows no close button under the pointer")
            let point = CGPoint(x: cell.frame.minX + rect.midX, y: cell.frame.minY + rect.midY)
            return strip.convert(strip.convert(point, from: strip.tabsClip), to: nil)
        }

        func click(_ point: CGPoint, count: Int = 1) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                window.sendEvent(event)
            }
        }

        /// Lets the strip's model observation run (its sync after a close).
        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }

        var selects: Int { intents.filter { if case .select = $0 { true } else { false } }.count }
    }

    @Test func thePlusButtonOpensANewTab() async throws {
        let harness = Harness(count: 3)
        defer { harness.window.closeAfterTest() }
        let plus = harness.strip.convert(harness.strip.newTabButton.frame, from: harness.strip.contentView)
        try #require(!harness.strip.newTabButton.isHidden && plus.width > 0, "the strip shows no + button")
        harness.click(harness.strip.convert(CGPoint(x: plus.midX, y: plus.midY), to: nil))
        #expect(harness.intents.contains { if case .newTab = $0 { true } else { false } }, "\(harness.intents)")
    }

    @Test func doubleClickingEmptyStripSpaceOpensNoTab() async throws {
        let harness = Harness(count: 2)
        defer { harness.window.closeAfterTest() }
        await harness.settle()
        let plus = harness.strip.convert(harness.strip.newTabButton.frame, from: harness.strip.contentView)
        let empty = CGPoint(x: (plus.maxX + harness.strip.bounds.maxX) / 2, y: harness.strip.bounds.midY)
        try #require(harness.strip.titlebarHit(at: empty) == .empty, "no empty strip space after the + button")
        harness.click(harness.strip.convert(empty, to: nil))
        harness.click(harness.strip.convert(empty, to: nil), count: 2)
        #expect(harness.intents.isEmpty, "\(harness.intents)")
    }

    @Test func clickingCloseUnderAStillPointerClosesTheNextTabEachTime() async throws {
        let harness = Harness(count: 6)
        defer { harness.window.closeAfterTest() }
        await harness.settle()
        let point = try harness.closeButton(TabID("tab1"))
        for _ in 0..<4 {
            harness.click(point)
            await harness.settle()
        }
        #expect(harness.closed.map(\.rawValue) == ["tab1", "tab2", "tab3", "tab4"])
        #expect(harness.selects == 0, "a click meant for a close button selected a tab")
    }

    @Test func clicksFasterThanTheStripSyncsStillCloseOneTabEach() async throws {
        let harness = Harness(count: 6)
        defer { harness.window.closeAfterTest() }
        await harness.settle()
        let point = try harness.closeButton(TabID("tab1"))
        // No turn for the strip's model sync between the clicks.
        for _ in 0..<3 { harness.click(point) }
        await harness.settle()
        #expect(harness.closed.map(\.rawValue) == ["tab1", "tab2", "tab3"], "one close per click, each the tab under the pointer")
        #expect(harness.selects == 0, "a click meant for a close button selected a tab")
    }

    /// Chrome's closing mode: the strip does not reflow under the pointer. After mouse closes every
    /// tab keeps its width, until the pointer leaves the strip (closing mode's exit); then the tabs
    /// widen to fill it.
    @Test func theTabsKeepTheirWidthsUntilThePointerLeaves() async throws {
        let harness = Harness(count: 6)
        defer { harness.window.closeAfterTest() }
        await harness.settle()
        let widths = Dictionary(uniqueKeysWithValues: TabClosingModeHit.laidOut(harness.strip).map { ($0.id, $0.frame.width) })
        let point = try harness.closeButton(TabID("tab1"))
        for _ in 0..<2 {
            harness.click(point)
            await harness.settle()
        }
        let held = TabClosingModeHit.laidOut(harness.strip)
        #expect(held.map(\.id.rawValue) == ["tab0", "tab3", "tab4", "tab5"])
        for tab in held {
            #expect(abs(tab.frame.width - (widths[tab.id] ?? 0)) < 0.5, "\(tab.id.rawValue) changed width under the pointer")
        }
        harness.strip.closingWatch.exit()
        await harness.settle()
        for tab in TabClosingModeHit.laidOut(harness.strip) {
            #expect(tab.frame.width > (widths[tab.id] ?? 0) + 0.5, "\(tab.id.rawValue) did not widen once the pointer left")
        }
    }

    /// On screen the closed tab shrinks away and the next one slides in under the pointer;
    /// a click before that ends is for the close button arriving there.
    @Test(.enabled("a window with no screen applies its changes at once") { await MainActor.run { !NSScreen.screens.isEmpty } },
          .enabled("animation speed is off on this host") { await MainActor.run { Motion.speed != .off } })
    func aClickWhileTheNextTabSlidesInClosesIt() throws {
        let harness = Harness(count: 6)
        defer { harness.window.closeAfterTest() }
        harness.window.setFrameOrigin(NSPoint(x: 200, y: 200))
        try #require(harness.window.screen != nil)
        harness.strip.sync(fromModel: true)
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let point = try harness.closeButton(TabID("tab1"))
        for _ in 0..<3 {
            harness.click(point)
            // The strip's sync, with no animation frame after it: every tab is where it started.
            harness.strip.sync(fromModel: true)
        }
        #expect(harness.closed.map(\.rawValue) == ["tab1", "tab2", "tab3"], "one close per click, each the tab arriving under the pointer")
        #expect(harness.selects == 0, "a click meant for a close button selected a tab")
    }

    /// Four untitled tabs `width` wide in a 700 pt strip, the third with a status: a hovered tab with a status
    /// and no title draws its x in its icon's centered slot, its plain neighbor at the trailing edge.
    private static func closeSlotStrip(width: (TabStripMetrics) -> CGFloat) -> (strip: TabStripView, window: NSWindow) {
        let model = TabStripModel(tabs: [
            TabItem(id: TabID("tab0"), title: "Tab 0"),
            TabItem(id: TabID("plain"), title: "Plain"),
            TabItem(id: TabID("waiting"), title: "Waiting", status: .needsInput),
            TabItem(id: TabID("tab3"), title: "Tab 3"),
        ], selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        var metrics = TabStripMetrics.standard
        let tabWidth = width(metrics)
        metrics.maxTabWidth = tabWidth
        metrics.minActiveTabWidth = tabWidth
        metrics.minInactiveTabWidth = tabWidth
        strip.customMetrics = metrics
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)
        return (strip, window)
    }

    /// Tab `id`'s drawn x with the pointer on it, in the clip (the pointer stays there).
    private static func hoveredClose(_ id: TabID, in strip: TabStripView) throws -> CGRect {
        let cell = try #require(strip.cells[id])
        TabStripDebug.pointerMoved(in: strip, to: strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip))
        let rect = try #require(cell.closeButtonRect, "tab \(id.rawValue) shows no close button under the pointer")
        return rect.offsetBy(dx: cell.frame.minX, dy: cell.frame.minY)
    }

    /// Codex review of #36837: a hovered untitled tab with a status draws its x in its icon's centered slot,
    /// its neighbor without one at the trailing edge. Closing mode's next-close hit follows each tab's own x,
    /// never the last press's offset from the trailing edge: the press at the status tab's x closes it, the
    /// point the plain tab's offset would give it closes nothing.
    @Test func theNextCloseFollowsEachTabsOwnCloseSlot() throws {
        // Untitled, so a status draws on the icon, yet wide enough that the plain tab's offset, carried onto the
        // status tab, lands past the centered x's click target (``TabStripMetrics/closeHitRect(_:)``, 20 pt): the
        // gap between the two x's is half the tab less the trailing x's inset. A favicon-and-x tab is too narrow
        // for that once the x shrank to Compact's 10 pt, and its 20 pt target reached the carried point.
        let (strip, window) = Self.closeSlotStrip { m in
            let side = m.closeButtonSize
            let reach = m.closeHitRect(CGRect(x: 0, y: 0, width: side, height: side)).width / 2
            return max(m.faviconCloseWidth, 2 * (m.tabBackgroundInset + m.contentTrailingInset + side / 2 + reach + 2))
        }
        defer { window.closeAfterTest() }
        let plain = try Self.hoveredClose(TabID("plain"), in: strip)
        let waiting = try Self.hoveredClose(TabID("waiting"), in: strip)
        let plainCell = try #require(strip.cells[TabID("plain")]), waitingCell = try #require(strip.cells[TabID("waiting")])
        let carried = CGPoint(x: waitingCell.frame.maxX - (plainCell.frame.maxX - plain.midX), y: plain.midY)
        // The fixture is what the review describes: the two x's sit at different offsets in their tabs, far enough
        // apart that no click on the status tab's x reaches the carried point.
        try #require(!strip.metrics.closeHitRect(waiting).contains(carried),
                     "the carried point \(carried) is on the waiting tab's x \(waiting) (plain's \(plain))")

        strip.closingHit.closePressed(at: CGPoint(x: plain.midX, y: plain.midY))
        // Where the waiting tab's x really is: a press there closes it.
        #expect(strip.closingHit.tab(at: CGPoint(x: waiting.midX, y: waiting.midY), in: strip) == TabID("waiting"))
        // The plain tab's trailing offset, carried onto the waiting tab: no x is there.
        #expect(strip.closingHit.tab(at: carried, in: strip) == nil, "a press where the waiting tab draws no x closed it")
        // And the plain tab still takes a press at its own x.
        #expect(strip.closingHit.tab(at: CGPoint(x: plain.midX, y: plain.midY), in: strip) == TabID("plain"))
    }

    /// Closing mode's next close and a hovered click agree on every point of a tab (`TabStripView.isInCloseButton`):
    /// the x's 20 pt target where the cell draws it, on the pixel grid, the trailing edge excluded. Untitled
    /// favicon-and-x tabs, where the status tab's centered x falls between pixels before it is aligned.
    @Test func theNextCloseHitsWhereAHoveredClickCloses() throws {
        let (strip, window) = Self.closeSlotStrip { $0.faviconCloseWidth }
        defer { window.closeAfterTest() }
        let anchor = try Self.hoveredClose(TabID("plain"), in: strip)
        strip.closingHit.closePressed(at: CGPoint(x: anchor.midX, y: anchor.midY))
        for id in [TabID("plain"), TabID("waiting")] {
            let close = try Self.hoveredClose(id, in: strip)
            let cell = try #require(strip.cells[id])
            // Between pixels at every backing scale, so no point sits on an edge.
            var x = cell.frame.minX + 1.25, mismatches: [String] = []
            while x < cell.frame.maxX - 1 {
                let point = CGPoint(x: x, y: close.midY)
                let clicked = strip.isInCloseButton(id, strip.convert(point, from: strip.tabsClip))
                let next = strip.closingHit.tab(at: point, in: strip)
                if next != (clicked ? id : nil) { mismatches.append("x \(x): click \(clicked), next \(next?.rawValue ?? "nil")") }
                x += 0.5
            }
            #expect(mismatches.isEmpty, "\(id.rawValue) (cell \(cell.frame), x \(close)): \(mismatches.joined(separator: "; "))")
        }
    }
}

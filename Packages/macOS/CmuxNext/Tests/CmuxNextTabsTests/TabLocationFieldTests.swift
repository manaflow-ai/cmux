import AppKit
import Testing
@testable import CmuxNextTabs

/// The strip's location field: the selected browser tab's address in the
/// free space after the tabs, hidden when that tab has none or the space is
/// short, and a click that asks the App to focus the address bar.
@MainActor @Suite(.serialized) struct TabLocationFieldTests {
    static let page = TabLocation(address: "https://github.com/manaflow-ai/cmux/pull/123")
    static let plain = TabLocation(address: "http://example.com/a")

    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView
        var intents: [TabStripIntent] = []

        init(tabs: [TabItem], selected: TabID? = nil, width: CGFloat = 900, buttons: [TabStripButton] = []) {
            model = TabStripModel(tabs: tabs, selectedID: selected ?? tabs.first?.id, trailingButtons: buttons)
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            model.intentHandler = { [unowned self] in self.intents.append($0) }
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
            strip.relayout(animated: false)
        }

        var field: TabLocationFieldView { strip.locationField }

        /// The field's frame in strip coordinates.
        var fieldFrame: CGRect { field.superview!.convert(field.frame, to: strip) }

        var fieldCenter: CGPoint { CGPoint(x: fieldFrame.midX, y: fieldFrame.midY) }

        func event(_ type: NSEvent.EventType, at stripPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: strip.convert(stripPoint, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }

        func close() { window.close() }
    }

    static func browser(_ id: String, _ location: TabLocation?) -> TabItem {
        TabItem(id: TabID(id), title: id, icon: .symbol("globe"), location: location)
    }

    // MARK: Layout math

    @Test func theFieldFillsTheFreeSpaceUpToItsAddress() {
        let frame = TabLocationFieldLayout.frame(runEnd: 100, limit: 600, naturalWidth: 200, gap: 8, y: 4, height: 28)
        #expect(frame == CGRect(x: 108, y: 4, width: 200, height: 28))
        let long = TabLocationFieldLayout.frame(runEnd: 100, limit: 400, naturalWidth: 900, gap: 8, y: 4, height: 28)
        #expect(long == CGRect(x: 108, y: 4, width: 292, height: 28), "a long address truncates, never passes the limit")
    }

    @Test func theFieldHidesBelowTheMinimumWidthOrWithoutAnAddress() {
        let minimum = TabLocationFieldLayout.minimumWidth
        #expect(TabLocationFieldLayout.frame(runEnd: 0, limit: minimum + 8, naturalWidth: 50, gap: 8, y: 0, height: 28) != nil)
        #expect(TabLocationFieldLayout.frame(runEnd: 0, limit: minimum + 7, naturalWidth: 50, gap: 8, y: 0, height: 28) == nil)
        #expect(TabLocationFieldLayout.frame(runEnd: 0, limit: 600, naturalWidth: 0, gap: 8, y: 0, height: 28) == nil)
    }

    /// A strip that is the window's titlebar keeps `dragReserve` of empty
    /// strip after the field, so the window can still be dragged.
    @Test func aTitlebarStripKeepsADragReserve() {
        let reserve = TabLocationFieldLayout.dragReserve
        #expect(reserve >= 80)
        let capped = TabLocationFieldLayout.frame(runEnd: 100, limit: 500, naturalWidth: 900, gap: 8, reserve: reserve, y: 0, height: 28)
        #expect(capped?.maxX == 500 - reserve)
        let short = TabLocationFieldLayout.frame(runEnd: 100, limit: 500, naturalWidth: 100, gap: 8, reserve: reserve, y: 0, height: 28)
        #expect(short?.width == 100, "a short address keeps its own width")
        let minimum = TabLocationFieldLayout.minimumWidth
        let limit = 100 + 8 + minimum + reserve
        #expect(TabLocationFieldLayout.frame(runEnd: 100, limit: limit, naturalWidth: 900, gap: 8, reserve: reserve, y: 0, height: 28) != nil)
        #expect(TabLocationFieldLayout.frame(runEnd: 100, limit: limit - 1, naturalWidth: 900, gap: 8, reserve: reserve, y: 0, height: 28) == nil,
                "under the minimum after the reserve, the field hides")
    }

    @Test func theRunEndIsTheLaterOfDrawnAndTarget() {
        #expect(TabLocationFieldLayout.runEnd(current: 120, target: 200) == 200, "a tab growing in pushes the field at once")
        #expect(TabLocationFieldLayout.runEnd(current: 200, target: 120) == 200, "a closing tab never slides under it")
    }

    // MARK: Strip

    @Test func aSelectedBrowserTabShowsItsLocationAfterTheTabs() throws {
        let h = Harness(tabs: [Self.browser("a", Self.page), TabItem(id: "b", title: "Terminal")])
        defer { h.close() }
        #expect(!h.field.isHidden)
        #expect(h.field.location == Self.page)
        let plus = h.strip.newTabButton.superview!.convert(h.strip.newTabButton.frame, to: h.strip)
        #expect(h.fieldFrame.minX >= plus.maxX, "never over the tabs or +")
        #expect(h.fieldFrame.maxX <= h.strip.bounds.width - h.strip.metrics.stripHorizontalPadding)
        #expect(h.strip.titlebarHit(at: h.fieldCenter) == .strip, "the field never drags the window")
        // The field's column is the full strip height: no dead band above or below the text.
        let top = CGPoint(x: h.fieldFrame.midX, y: 0.5)
        let bottom = CGPoint(x: h.fieldFrame.midX, y: h.strip.bounds.height - 0.5)
        #expect(h.field.hit(top, from: h.strip) && h.field.hit(bottom, from: h.strip))
        #expect(h.strip.titlebarHit(at: top) == .strip)
        #expect(h.strip.accessibilityChildren()?.contains { ($0 as AnyObject) === h.field } == true)
    }

    @Test func theFieldStopsBeforeTheTrailingButtons() {
        let buttons = [TabStripButton(id: "cmux.splitRight", icon: .symbol("square.split.2x1"), toolTip: "Split Right",
                                      accessibilityLabel: "Split Right")]
        let long = TabLocation(address: "https://example.com/" + String(repeating: "segment/", count: 80))
        let h = Harness(tabs: [Self.browser("a", long)], buttons: buttons)
        defer { h.close() }
        #expect(!h.field.isHidden)
        let group = h.strip.buttonGroup.superview!.convert(h.strip.buttonGroup.frame, to: h.strip)
        #expect(h.fieldFrame.maxX <= group.minX)
    }

    @Test func aTabWithoutALocationHidesTheField() {
        let h = Harness(tabs: [Self.browser("a", Self.page), TabItem(id: "b", title: "Terminal")], selected: "b")
        defer { h.close() }
        #expect(h.field.isHidden)
        #expect(h.strip.accessibilityChildren()?.contains { ($0 as AnyObject) === h.field } == false)

        h.model.selectedID = "a"
        h.strip.sync(fromModel: true)
        #expect(!h.field.isHidden)
        h.model.tabs[0].location = nil
        h.strip.sync(fromModel: true)
        #expect(h.field.isHidden, "the New Tab page or an internal page clears it")
    }

    @Test func aNarrowStripHidesTheField() {
        let h = Harness(tabs: [Self.browser("a", Self.page)], width: 260)
        defer { h.close() }
        #expect(h.field.isHidden)
    }

    @Test func tabsThatFillTheStripHideTheField() {
        let tabs = [Self.browser("a", Self.page)] + (1..<14).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let h = Harness(tabs: tabs)
        defer { h.close() }
        #expect(h.field.isHidden)
    }

    @Test func aClickAsksToFocusTheAddressBar() {
        let h = Harness(tabs: [Self.browser("a", Self.page)])
        defer { h.close() }
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: h.fieldCenter))
        #expect(h.field.isPressed)
        #expect(h.intents.isEmpty, "nothing runs before the release")
        h.strip.mouseUp(with: h.event(.leftMouseUp, at: h.fieldCenter))
        #expect(h.intents == [.focusLocation])
        #expect(!h.field.isPressed)
    }

    @Test func aReleaseOffTheFieldDoesNothing() {
        let h = Harness(tabs: [Self.browser("a", Self.page)])
        defer { h.close() }
        let outside = CGPoint(x: h.fieldFrame.maxX + 40, y: h.fieldCenter.y)
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: h.fieldCenter))
        h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: outside))
        #expect(!h.field.isPressed)
        h.strip.mouseUp(with: h.event(.leftMouseUp, at: outside))
        #expect(h.intents.isEmpty)
    }

    @Test func voiceOverPressesAndReadsTheHost() throws {
        let h = Harness(tabs: [Self.browser("a", Self.plain)])
        defer { h.close() }
        let label = try #require(h.field.accessibilityLabel())
        #expect(label.contains("example.com"))
        #expect(h.field.accessibilityHelp() == "http://example.com/a")
        #expect(h.field.accessibilityRole() == .button)
        #expect(h.field.accessibilityPerformPress())
        #expect(h.intents == [.focusLocation])
    }

    @Test func aHiddenFieldIgnoresVoiceOverPresses() {
        let h = Harness(tabs: [TabItem(id: "a", title: "Terminal")])
        defer { h.close() }
        #expect(h.field.isHidden)
        #expect(!h.field.accessibilityPerformPress())
        #expect(h.intents.isEmpty)
    }

    @Test func helpAndTooltipTextNeverCarryCredentials() {
        let h = Harness(tabs: [Self.browser("a", TabLocation(address: "https://me:pw@example.com/a"))])
        defer { h.close() }
        #expect(h.field.accessibilityHelp() == "https://example.com/a")
        #expect(h.field.displayURL == "https://example.com/a")
    }
}

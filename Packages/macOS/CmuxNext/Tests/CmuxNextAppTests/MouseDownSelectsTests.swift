import AppKit
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

private typealias StripTab = CmuxNextTabs.TabID

/// Lawrence 2026-10-18: "MouseDown on Home and App Store failed to change the workspace
/// immediately. We need to do the same thing for Tabs, where mouse down changes it immediately."
/// Home and the App Store switch on the press, like a workspace row and like a tab in a pane's
/// strip; a press that becomes a drag still drags, and the release never runs them a second time.
/// Other sidebar items (Settings, launchers) still act on release only.
@MainActor @Suite(.serialized) struct MouseDownSelectsTests {
    final class BandHarness {
        let region = SidebarRegionView(region: .top)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var activated: [LayoutItemID] = []
        static let home = LayoutItemID("itm_home"), appStore = LayoutItemID("itm_app_store"), settings = LayoutItemID("itm_settings")

        init() {
            let items = [LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef),
                         LayoutItem(id: Self.appStore, ref: .app("cmux/app-store")),
                         LayoutItem(id: Self.settings, ref: .builtIn(.settings))]
            let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)
            let content = SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                                    metrics: .standard, drawsLines: false)
            region.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
            region.update(content, width: 240)
            window.contentView = region
            window.orderFrontRegardless()
            region.layoutSubtreeIfNeeded()
            region.onActivateWithModifiers = { [unowned self] id, _ in activated.append(id) }
        }

        func view(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(region.itemView(id), "the band draws no \(id.rawValue) item")
            view.layoutSubtreeIfNeeded()
            return view
        }

        /// The event `type` at the center of `view`, in window coordinates.
        func event(_ type: NSEvent.EventType, on view: NSView, dy: CGFloat = 0) throws -> NSEvent {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY + dy), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                   pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    @Test(arguments: ["itm_home", "itm_app_store"])
    func homeAndTheAppStoreSwitchOnMouseDownAndOnlyOnce(_ raw: String) throws {
        let id = LayoutItemID(raw)
        let harness = BandHarness()
        defer { harness.window.orderOut(nil) }
        let view = try harness.view(id)
        view.mouseDown(with: try harness.event(.leftMouseDown, on: view))
        #expect(harness.activated == [id], "the press did not switch")
        view.mouseUp(with: try harness.event(.leftMouseUp, on: view))
        #expect(harness.activated == [id], "the release ran the item a second time")
    }

    @Test func otherItemsStillActOnRelease() throws {
        let harness = BandHarness()
        defer { harness.window.orderOut(nil) }
        let view = try harness.view(BandHarness.settings)
        view.mouseDown(with: try harness.event(.leftMouseDown, on: view))
        #expect(harness.activated.isEmpty, "Settings opened on the press")
        view.mouseUp(with: try harness.event(.leftMouseUp, on: view))
        #expect(harness.activated == [BandHarness.settings])
    }

    @Test func aPressThatBecomesADragStillDragsAndSwitchesOnce() throws {
        let harness = BandHarness()
        defer { harness.window.orderOut(nil) }
        let view = try harness.view(BandHarness.home)
        var drags = 0, ended = 0
        view.onDragged = { _, _ in drags += 1; return true }
        view.onDragEnded = { ended += 1 }
        view.mouseDown(with: try harness.event(.leftMouseDown, on: view))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, on: view, dy: 30))
        view.mouseUp(with: try harness.event(.leftMouseUp, on: view, dy: 30))
        #expect(drags == 1 && ended == 1, "the press did not drag")
        #expect(harness.activated == [BandHarness.home])
    }

    @Test func aPaneTabSelectsOnMouseDownBeforeTheRelease() throws {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: StripTab("tab\($0)"), title: "Tab \($0)") }, selectedID: StripTab("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        var selected: [StripTab] = []
        model.intentHandler = { if case .select(let id) = $0 { selected.append(id) } }
        let cell = try #require(strip.cells[StripTab("tab2")])
        let point = strip.convert(strip.convert(CGPoint(x: cell.frame.minX + 12, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        strip.mouseDown(with: down)
        #expect(selected == [StripTab("tab2")], "the tab did not select on the press")
        #expect(strip.press != nil, "the press was not kept for a drag")
    }
}

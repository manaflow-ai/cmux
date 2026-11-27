import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// #22807: in a translucent window a dragged tab stays glass. `DragGlassTests` sets `isLifted` on a lone cell; this
/// drags a real tab in a real strip with the pointer, across its neighbours (each reorder lays the strip out again and
/// the selection the press made syncs back from the model), and reads the lifted cell's fill at every step: a thicker
/// piece of the window's glass (`WindowBackdrop.dragLiftAlpha`), never the solid theme block. Blur and alpha do not
/// show in a capture, so the cell's own layer is the evidence.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabDragStaysGlassTests {
    @Test func theLiftedTabKeepsItsGlassFillWhileItIsDragged() throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        var input = original
        input.backgroundOpacity = 0.65 // cmux.json `appearance.backgroundOpacity` 0.65, `backgroundBlur` "frosted"
        input.backgroundBlur = 20
        _ = ThemeScope.app.store.apply(input)

        let model = TabStripModel(tabs: (0..<5).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
        model.intentHandler = { intent in if case .select(let id) = intent { model.selectedID = id } }
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()

        func point(_ id: String, dx: CGFloat = 12) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)], "no cell for \(id)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + dx, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        let cell = try #require(strip.cells[TabID("t1")])
        let backdrop = WindowBackdrop.dragPreview(cell.themeScope)
        let reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #expect(backdrop.dragsOnGlass == !reducesTransparency, "the fixture's window is not translucent")
        let glassAlpha = backdrop.dragsOnGlass ? backdrop.dragLiftAlpha : 1

        /// The lifted cell's fill is the window's glass, thicker: not solid, not the resting tab's.
        func expectGlass(_ when: String) throws {
            #expect(cell.isLifted, "\(when): the tab is not lifted")
            let fill = try #require(cell.backgroundLayer.backgroundColor, "\(when): the lifted tab has no fill")
            #expect(abs(fill.alpha - glassAlpha) < 0.001, "\(when): the lifted tab's fill alpha is \(fill.alpha), not the glass's \(glassAlpha)")
            if backdrop.dragsOnGlass { #expect(fill.alpha < 1, "\(when): the lifted tab turned solid") }
        }

        // Press t1 (it selects on the press), drag it past t3, let go.
        let start = try point("t1")
        let end = try point("t3", dx: 80)
        strip.mouseDown(with: try event(.leftMouseDown, at: start))
        strip.syncFromModel() // the App's echo of the press's selection
        for step in 1...8 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 8
            strip.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: x, y: start.y)))
            try expectGlass("step \(step)")
            if step == 4 {
                strip.syncFromModel() // a model change mid-drag (a title, the selection) draws the cells again
                try expectGlass("after a sync mid-drag")
            }
        }
        strip.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: end.x, y: start.y)))
        #expect(!cell.isLifted, "the tab stays lifted after the drop")
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's resize edge works whatever has focus (Leo 2026-10-20: "when im focused in
/// chromium/a browser tab i should also be able to resize the left sidebar"). A Chromium page is a
/// child window above this one and holds key while it has focus. The handle's first click only
/// brought the window forward, and the band's part over the page went to the page. Pane dividers
/// already had both covered: they take the first mouse and their hit areas get a catcher panel
/// above pages (`DividerMouseCatchers`), which also sets the cursor while the page holds key.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarResizeAbovePageTests {
    func root(sidebarHidden: Bool = false) -> (ShellWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        if sidebarHidden { model.presentation = .hidden }
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        if sidebarHidden {
            root.sidebar.isHidden = true
            root.sidebarHidden = true
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    func handle(in root: NSView) throws -> NSView {
        let views = sequence(state: [root]) { stack -> NSView? in
            guard !stack.isEmpty else { return nil }
            let view = stack.removeLast()
            stack.append(contentsOf: view.subviews)
            return view
        }
        return try #require(views.first { String(describing: type(of: $0)) == "SidebarResizeHandle" }, "the sidebar has a resize handle")
    }

    /// Areas the window's catcher panels cover that resize columns and lie on the sidebar's edge.
    func sidebarAreas(in window: ShellWindow, root: WindowRootView) -> [CGRect] {
        let edge = root.sidebar.convert(root.sidebar.bounds, to: nil).maxX
        return window.overlayLayer.catcherAreas.filter { $0.resizesColumns && $0.rect.minX < edge && $0.rect.maxX > edge }.map(\.rect)
    }

    /// The press that makes the window key (a page had it) starts the drag.
    @Test func theHandleTakesTheFirstClick() throws {
        let (window, root) = root()
        defer { window.close() }
        #expect(try handle(in: root).acceptsFirstMouse(for: nil))
    }

    /// The whole band gets a catcher panel above pages, like a pane divider's hit area.
    @Test func theBandIsACatcherArea() throws {
        let (window, root) = root()
        defer { window.close() }
        let band = try handle(in: root).convert(try handle(in: root).bounds, to: nil)
        #expect(sidebarAreas(in: window, root: root) == [band], "areas \(window.overlayLayer.catcherAreas), band \(band)")
    }

    @Test func theCatcherAreaFollowsTheSidebarWidth() throws {
        let (window, root) = root()
        defer { window.close() }
        let before = try handle(in: root).convert(try handle(in: root).bounds, to: nil)
        root.sidebar.restore(width: root.sidebar.model.width + 60, presentation: .shown)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        let band = try handle(in: root).convert(try handle(in: root).bounds, to: nil)
        #expect(band.minX > before.minX, "band \(before) -> \(band)")
        #expect(sidebarAreas(in: window, root: root) == [band], "areas \(window.overlayLayer.catcherAreas), band \(band)")
    }

    @Test func aHiddenSidebarHasNoCatcherArea() throws {
        let (window, _) = root(sidebarHidden: true)
        defer { window.close() }
        #expect(window.overlayLayer.sidebarResizeArea == nil)
        #expect(!window.overlayLayer.catcherAreas.contains { $0.id == WindowOverlayLayer.sidebarResizeAreaID }, "\(window.overlayLayer.catcherAreas)")
    }

    /// `debug.layers` publishes `dividerAreas` as `divider_areas_in_window`, and the perf gate and
    /// live drag scripts take its leftmost vertical area as the first pane divider. The sidebar's
    /// band is no pane divider: with it in the list they dragged the sidebar edge instead. The
    /// catcher panels still cover it.
    @Test func theDividerAreasLeaveOutTheBand() throws {
        let (window, _) = root()
        defer { window.close() }
        let layer = window.overlayLayer
        #expect(!layer.dividerAreas.contains { $0.id == WindowOverlayLayer.sidebarResizeAreaID }, "\(layer.dividerAreas)")
        let band = try #require(layer.sidebarResizeArea)
        #expect(layer.catcherAreas == layer.dividerAreas + [band], "catchers \(layer.catcherAreas)")
    }

    /// With a Chromium page focused, a move from the page straight onto the band's part beside it
    /// (over the sidebar, out of the page window) showed the arrow: the catcher set the resize
    /// cursor on its enter, then AppKit put the arrow back for the key page window in the same
    /// event turn, and the panel, never key, got no cursor update or move after that (real
    /// pointer on a fleet capture mini, 2026-10-22). The catcher sets its cursor once more on the
    /// next turn while the pointer is still over it.
    @Test func theCatcherSetsItsCursorAgainAfterTheEnterTurn() async throws {
        let catcher = try enteredCatcher(pointerOver: true)
        NSCursor.arrow.set() // AppKit's reset for the key page window, later in the enter's turn.
        let pending = catcher.pendingCursorSet
        #expect(pending != nil, "the enter queues a cursor set")
        await pending?.value
        #expect(isColumnResize(NSCursor.current), "cursor hot spot \(NSCursor.current.hotSpot), size \(NSCursor.current.image.size)")
    }

    /// A pointer that left the catcher again keeps the cursor it has.
    @Test func anExitedCatcherLeavesTheCursorAlone() async throws {
        let catcher = try enteredCatcher(pointerOver: true)
        catcher.mouseExited(with: try enterExit(.mouseExited))
        NSCursor.arrow.set()
        await catcher.pendingCursorSet?.value
        #expect(!isColumnResize(NSCursor.current), "cursor hot spot \(NSCursor.current.hotSpot), size \(NSCursor.current.image.size)")
    }

    /// The panel was parked, hidden or moved off the pointer before the queued set ran (no exit
    /// comes then): the cursor stays as it is.
    @Test func aCatcherNoLongerUnderThePointerLeavesTheCursorAlone() async throws {
        let catcher = try enteredCatcher(pointerOver: false)
        NSCursor.arrow.set()
        await catcher.pendingCursorSet?.value
        #expect(!isColumnResize(NSCursor.current), "cursor hot spot \(NSCursor.current.hotSpot), size \(NSCursor.current.image.size)")
    }

    /// Out of a window (or in one that does not show) the pointer is never over the catcher.
    @Test func aCatcherOutOfAShownPanelIsNeverUnderThePointer() {
        _ = NSApplication.shared
        #expect(!DividerMouseCatcherView(frame: CGRect(x: 0, y: 0, width: 10, height: 200)).isPointerOver())
    }

    func enteredCatcher(pointerOver: Bool) throws -> DividerMouseCatcherView {
        _ = NSApplication.shared
        let catcher = DividerMouseCatcherView(frame: CGRect(x: 0, y: 0, width: 10, height: 200))
        catcher.isPointerOver = { pointerOver }
        catcher.mouseEntered(with: try enterExit(.mouseEntered))
        return catcher
    }

    func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: CGPoint(x: 5, y: 100), modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    func isColumnResize(_ cursor: NSCursor) -> Bool {
        let resize: NSCursor
        if #available(macOS 15, *) { resize = .columnResize } else { resize = .resizeLeftRight }
        return cursor.hotSpot == resize.hotSpot && cursor.image.size == resize.image.size
    }
}

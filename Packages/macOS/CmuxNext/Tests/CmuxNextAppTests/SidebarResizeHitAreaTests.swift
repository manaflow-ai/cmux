import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's resize edge is easy to grab (Lawrence 2026-10-19, u2255: "right now there isn't
/// one ... I don't want to change the spacing at all"). The handle straddled the sidebar's edge
/// but lived inside the sidebar container, so AppKit clipped its outer half: clicks, the resize
/// cursor and hover only reached the 3.5 pt inside the sidebar, and the 6 pt gutter beside it did
/// nothing. The band now reaches across the gutter and 2 pt into the sidebar, over its
/// neighbors, and moves no frame.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarResizeHitAreaTests {
    func root(sidebarHidden: Bool = false) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        if sidebarHidden { model.presentation = .hidden }
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
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

    /// What a click at `x` (root coordinates) halfway down the window lands on.
    func hit(atX x: CGFloat, in root: WindowRootView, window: NSWindow) throws -> NSView? {
        let frameView = try #require(window.contentView?.superview)
        let point = root.convert(CGPoint(x: x, y: root.bounds.midY), to: nil)
        return frameView.hitTest(frameView.convert(point, from: nil))
    }

    @Test(arguments: [-2.0, -1.0, -0.5, 0.5, 1.0, 5.0] as [CGFloat])
    func aClickNearTheSidebarEdgeReachesTheHandle(offset: CGFloat) throws {
        let (window, root) = root()
        defer { window.close() }
        let handle = try handle(in: root)
        let edge = root.sidebar.frame.maxX
        #expect(try hit(atX: edge + offset, in: root, window: window) === handle, "a click \(offset) pt from the edge")
    }

    /// The resize cursor (cursor rects) and the hover line (tracking areas) stop at each
    /// ancestor's bounds: no ancestor may clip the band. (`visibleRect` is not reliable in a
    /// window that is never on screen, as on the fleet.)
    @Test func theWholeBandShowsTheResizeCursor() throws {
        let (window, root) = root()
        defer { window.close() }
        let handle = try handle(in: root)
        #expect(handle.bounds.width >= 8, "the band is \(handle.bounds.width) pt")
        let band = handle.convert(handle.bounds, to: nil)
        for ancestor in sequence(first: handle.superview, next: { $0?.superview }).compactMap({ $0 }) {
            let clip = ancestor.convert(ancestor.bounds, to: nil)
            #expect(clip.intersection(band).width == band.width,
                    "\(type(of: ancestor)) clips the band to \(clip.intersection(band).width) of \(band.width) pt")
        }
    }

    @Test func theBandStaysThin() throws {
        let (window, root) = root()
        defer { window.close() }
        let edge = root.sidebar.frame.maxX
        let handle = try handle(in: root)
        #expect(try hit(atX: edge - 10, in: root, window: window) !== handle, "the sidebar keeps its rows' clicks")
        #expect(try hit(atX: root.contentHost.frame.minX + 6, in: root, window: window) !== handle, "the card keeps its clicks")
    }

    /// No spacing change: the sidebar keeps its width and the card its gutter.
    @Test func theBandMovesNoFrame() throws {
        let (window, root) = root()
        defer { window.close() }
        let sidebar = root.sidebar.frame, card = root.contentHost.frame
        #expect(sidebar.minX == 0)
        #expect(sidebar.width == root.sidebar.model.displayWidth)
        #expect(card.minX - sidebar.maxX == Metrics.mainPaneGutter)
    }

    @Test func aHiddenSidebarHasNoBand() throws {
        let (window, root) = root(sidebarHidden: true)
        defer { window.close() }
        let handle = try handle(in: root)
        #expect(try hit(atX: 2, in: root, window: window) !== handle)
    }
}

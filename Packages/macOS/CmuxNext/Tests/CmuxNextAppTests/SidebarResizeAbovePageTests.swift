import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// The sidebar's resize edge works whatever has focus (Leo 2026-10-20: "when im focused in
/// chromium/a browser tab i should also be able to resize the left sidebar"). A Chromium page is a
/// child window above this one and holds key while it has focus. The handle's first click only
/// brought the window forward, and the band's part over the page went to the page. Pane dividers
/// already had both covered: they take the first mouse and their hit areas get a catcher panel
/// above pages (`DividerMouseCatchers`), which also sets the cursor while the page holds key.
@MainActor @Suite(.serialized) struct SidebarResizeAbovePageTests {
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
        return window.overlayLayer.dividerAreas.filter { $0.resizesColumns && $0.rect.minX < edge && $0.rect.maxX > edge }.map(\.rect)
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
        #expect(sidebarAreas(in: window, root: root) == [band], "areas \(window.overlayLayer.dividerAreas), band \(band)")
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
        #expect(sidebarAreas(in: window, root: root) == [band], "areas \(window.overlayLayer.dividerAreas), band \(band)")
    }

    @Test func aHiddenSidebarHasNoCatcherArea() throws {
        let (window, root) = root(sidebarHidden: true)
        defer { window.close() }
        #expect(!window.overlayLayer.dividerAreas.contains { $0.id == WindowOverlayLayer.sidebarResizeAreaID }, "\(window.overlayLayer.dividerAreas)")
    }
}

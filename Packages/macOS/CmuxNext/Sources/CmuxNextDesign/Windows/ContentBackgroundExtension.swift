public import AppKit

/// Puts a window's main pane inside the system's background extension view while the glass sidebar experiment
/// extends it (``GlassSidebarLook/extendsContent``), and back out when it stops. The extension view fills the window
/// under the main pane; with automatic placement off it leaves the pane's frame and pins alone and draws the pane's
/// edges, mirrored and blurred, everywhere outside it (under the sidebar's glass card and its inset). The system
/// draws it from the pane's own layers, so its cost does not grow with rows, tabs or panes. Before macOS 26 it
/// extends nothing.
///
/// The pane moves between two parents in the same window: no window change, so its panes hear no window move. Its
/// pins live on the root (the common ancestor) and AppKit drops them with the old parent, so they are read before
/// the move and activated again after it. While the pane holds the whole window (a fullscreen page) the extension
/// stays and draws nothing: the pins swap inside the root as before.
@MainActor public final class ContentBackgroundExtension {
    /// The extension view while the pane is in it.
    public private(set) var host: NSView?

    public init() {}

    public var isExtending: Bool { host != nil }

    /// Mounts or unmounts so that `content` (a direct subview of `root`) is extended or not.
    public func apply(extending: Bool, content: NSView, in root: NSView) {
        if extending, host == nil {
            mount(content, in: root)
        } else if !extending, let host {
            unmount(content, from: host, in: root)
        }
    }

    private func mount(_ content: NSView, in root: NSView) {
        guard #available(macOS 26.0, *), content.superview === root else { return }
        let pins = Self.pins(of: content, in: root)
        let view = NSBackgroundExtensionView(frame: root.bounds)
        view.autoresizingMask = [.width, .height]
        view.automaticallyPlacesContentView = false
        root.addSubview(view, positioned: .below, relativeTo: content)
        view.contentView = content
        NSLayoutConstraint.activate(pins)
        host = view
        root.needsLayout = true
    }

    private func unmount(_ content: NSView, from host: NSView, in root: NSView) {
        let pins = Self.pins(of: content, in: root)
        if #available(macOS 26.0, *), let host = host as? NSBackgroundExtensionView { host.contentView = nil }
        root.addSubview(content, positioned: .above, relativeTo: host)
        host.removeFromSuperview()
        NSLayoutConstraint.activate(pins)
        self.host = nil
        root.needsLayout = true
    }

    /// The pane's active pins on the root: the side, edge, rail and page pins, whichever hold now.
    private static func pins(of content: NSView, in root: NSView) -> [NSLayoutConstraint] {
        root.constraints.filter { $0.isActive && ($0.firstItem === content || $0.secondItem === content) }
    }
}

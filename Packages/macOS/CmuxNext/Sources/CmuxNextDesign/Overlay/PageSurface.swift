public import AppKit

/// Where a window's Chromium pages draw (task 223 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// In process, Chromium shows each page in a window of its own (`CefNSWindow`) that the fork keeps
/// as a child window over its pane and re-adds above every other child when it shows or moves.
/// Only then does a window need the child-window machinery: the overlay host panel kept above page
/// windows, the layout planes moved into that panel, catcher panels over the divider hit areas, the
/// page window's key reclaim and child-window snapshots. With the Chromium Host the page is a view
/// in the window's own tree (`ChromiumHostPageView`, a `CALayerHost` on the host's context), as
/// Chrome's page is an `NSView` of the browser window
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm): app overlays draw above it in
/// the view tree, a divider takes the mouse as over any view, and none of that machinery runs.
public nonisolated enum PageSurface: Sendable, Equatable {
    /// Pages are child windows of the window (in-process Chromium).
    case childWindows
    /// Pages are views in the window's view tree (the Chromium Host).
    case views

    /// The surface `window` declares (``PageSurfaceHosting``). A window that declares none keeps its
    /// pages in child windows, the in-process default.
    @MainActor
    public static func of(_ window: NSWindow?) -> PageSurface {
        (window as? PageSurfaceHosting)?.pageSurface ?? .childWindows
    }
}

/// A window that says where its Chromium pages draw (``PageSurface``), fixed for the window's life:
/// every window that shows pages, from the process's browser backend (the App's main windows, a
/// tab's DevTools window and a popup page's window).
@MainActor
public protocol PageSurfaceHosting: NSWindow {
    /// Where this window's pages draw.
    var pageSurface: PageSurface { get }
}

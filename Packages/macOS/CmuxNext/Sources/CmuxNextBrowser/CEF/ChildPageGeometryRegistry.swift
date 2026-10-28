public import AppKit
import CmuxNextDesign

/// The pages of one window that follow its geometry: something moved the window's Chromium pages on
/// screen, or changed what clips them, without a frame change of their own views (dividers or the
/// sidebar moved, a clip or corner changed, the window moved). Every page view registers, whichever way
/// the page draws: a `CEFHostView` re-places the fork's page window (drawn in, or transparent over a
/// hosted page for its input), a host-mode ``ChromiumHostPageView`` reports its new screen rect, and the
/// cards over a page follow it (`PageFloatingOverlays`). Chrome needs no such request: its page view is
/// an ordinary subview that AppKit moves with its ancestors
/// (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`).
///
/// It replaces the app-wide `browserChildWindowPagesNeedUpdate` notification. The
/// window's layout owner asks through ``AppKit/NSWindow/updateBrowserPageGeometry(force:)``; only this
/// window's registered pages hear it (no other window's, and no NotificationCenter dispatch), and each
/// compares what it shows with its last update and tells the fork only on a change, so moving one page
/// of ten makes one fork geometry post.
///
/// Not a dirty set: every request visits every page of the window, and each reads its geometry to find
/// out whether it moved (a pane move does not reach the views inside it, and every request today is
/// window-wide). Chromium tells only the `RenderWidgetHostView`s whose bounds changed
/// (`content/browser/renderer_host/render_widget_host_view_mac.mm`, `SetBounds` / `UpdateScreenInfo`);
/// that needs the layout to name the panes it moved.
///
/// One per window, made on first registration and kept alive by the window (``of(_:)``), as
/// `WindowEvents` keeps one per window.
@MainActor
public final class ChildPageGeometryRegistry {
    /// A page's place in the registry: it stays registered while this object lives (the registry holds
    /// it weakly).
    @MainActor
    public final class Registration {
        fileprivate let update: @MainActor (_ force: Bool) -> Bool

        fileprivate init(update: @escaping @MainActor (_ force: Bool) -> Bool) {
            self.update = update
        }
    }

    private struct Entry {
        weak var registration: Registration?
    }

    private static let registries = ObjectAssociation<ChildPageGeometryRegistry>()

    private var entries: [Entry] = []

    /// A registry of no window (tests); the app uses ``of(_:)``.
    public init() {}

    /// `window`'s registry, made on first use and kept alive by the window.
    public static func of(_ window: NSWindow) -> ChildPageGeometryRegistry {
        if let existing = registries.value(on: window) { return existing }
        let registry = ChildPageGeometryRegistry()
        registries.set(registry, on: window)
        return registry
    }

    /// `window`'s registry when a page ever registered in it; a window with none has no page to update.
    static func existing(for window: NSWindow) -> ChildPageGeometryRegistry? {
        registries.value(on: window)
    }

    /// Registers a page. `update` re-applies the page's geometry and returns whether anything changed
    /// (`force`: re-apply even where nothing it reads changed, for a page window that something other
    /// than the fork moved). Keep the returned registration for as long as the page follows this window.
    public func register(_ update: @escaping @MainActor (_ force: Bool) -> Bool) -> Registration {
        let registration = Registration(update: update)
        entries.append(Entry(registration: registration))
        return registration
    }

    /// The pages registered now.
    public var count: Int { entries.count(where: { $0.registration != nil }) }

    /// Every page of the window checks its geometry and re-applies it where it changed (`force`: every
    /// page re-applies). Returns how many pages changed.
    @discardableResult
    public func pagesNeedUpdate(force: Bool = false) -> Int { // perf-hot: 0.5ms cef-geometry (once per layout change of the window)
        entries.removeAll { $0.registration == nil }
        // A page that registers or leaves while the others update waits for the next request.
        let current = entries.compactMap(\.registration)
        var changed = 0
        for registration in current where registration.update(force) {
            changed += 1
        }
        return changed
    }
}

public extension NSWindow {
    /// Asks every Chromium page of this window to re-apply its geometry, clip and occlusion
    /// (``ChildPageGeometryRegistry``): after the window's own native overlays over its content moved
    /// (`BrowserWindowOcclusionProviding`), a clip or corner changed with no page move, or the window
    /// moved or resized by any means (drag, Accessibility clients such as Rectangle, display or Space
    /// changes, fullscreen, deminiaturize). A page tells the fork only when what it reads changed since
    /// its last read; `force` makes every page re-apply (a page window moved by another app). Returns
    /// how many pages changed.
    @discardableResult
    func updateBrowserPageGeometry(force: Bool = false) -> Int {
        ChildPageGeometryRegistry.existing(for: self)?.pagesNeedUpdate(force: force) ?? 0
    }
}

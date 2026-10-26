public import AppKit

/// Implemented by a window whose Chromium pages follow its layout: it owns
/// the window's ``ChildPageGeometryRegistry``.
@MainActor
public protocol ChildPageGeometryHosting: AnyObject {
    var childPageGeometry: ChildPageGeometryRegistry { get }
}

/// The pages of one window that follow its geometry: the in-process page hosts
/// (`CEFHostView`), the layer-hosted page views (``ChromiumHostPageView``) and the
/// cards floating over pages (`PageFloatingOverlays`).
///
/// It replaces the app-wide `browserChildWindowPagesNeedUpdate` broadcast. The
/// window's layout owner calls ``pagesNeedUpdate(force:)`` after panes, dividers or
/// the sidebar moved, a clip or corner changed, or the window moved or resized;
/// only this window's registered pages hear it, and each re-applies only when what
/// it shows changed since its last update (the dirty set), so moving one page of
/// ten makes one fork geometry post. Chromium keeps the same split: the browser
/// view tells only the `RenderWidgetHostView`s whose bounds changed
/// (`content/browser/renderer_host/render_widget_host_view_mac.mm`,
/// `SetBounds` / `UpdateScreenInfo`), never every widget of the process.
@MainActor
public final class ChildPageGeometryRegistry {
    /// A page's place in the registry: it stays registered while this object lives
    /// (the registry holds it weakly).
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

    private var entries: [Entry] = []

    public init() {}

    /// The registry of `window`; nil for no window, or one with no Chromium page layout.
    public static func of(_ window: NSWindow?) -> ChildPageGeometryRegistry? {
        (window as? any ChildPageGeometryHosting)?.childPageGeometry
    }

    /// Registers a page. `update` re-applies the page's geometry and returns whether
    /// anything changed (`force`: re-apply even where nothing it reads changed, for a
    /// page window that something other than the fork moved). Keep the returned
    /// registration for as long as the page follows this window.
    public func register(_ update: @escaping @MainActor (_ force: Bool) -> Bool) -> Registration {
        let registration = Registration(update: update)
        entries.append(Entry(registration: registration))
        return registration
    }

    /// The pages registered now.
    public var count: Int { entries.count(where: { $0.registration != nil }) }

    /// Every page of the window re-applies its geometry where it changed (`force`:
    /// every page re-applies). Returns how many pages changed.
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

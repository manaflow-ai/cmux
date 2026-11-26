public import AppKit
import ObjectiveC

/// Views window mode: approach 3 of the Chromium integration study, "Chromium owns the window"
/// (cmuxterm-hq artifacts/in-tree-pages/approaches/views-window). It is a prototype on top of in-tree pages.
///
/// With the fork's `--cmux-views-window` switch (fork branch cmux/chromium-views-window, CMUX.md "Views window"), the
/// fork adopts the cmux window as a Chromium Views widget window at its first in-tree page. It isa-swizzles the window
/// to a runtime subclass named `<class>_CmuxViews` and puts Views' content view in the window's ``ViewsWindowSlotView``.
/// Each page is then a `views::WebView` of that widget at its container's rect, not a subview of the container: the
/// fork names the container on the page's `WebContentsViewCocoa`, and ``viewsContainer(of:)`` reads it back for the
/// window's focus rules. The switch is on for a dev build tagged `views-window…` (or `…-views-window…`) or with `CMUX_NEXT_VIEWS_WINDOW=1`, and it
/// implies in-tree pages (``decide(fileOverride:tag:environment:)``).
extension InTreePages {
    /// The fork's browser-process switch.
    public nonisolated static let viewsWindowSwitch = "cmux-views-window"
    /// The environment variable that turns the mode on (`1`) or off (`0`) for this launch.
    public nonisolated static let viewsWindowEnvironmentKey = "CMUX_NEXT_VIEWS_WINDOW"
    /// A dev build whose tag starts with this, or has it after a dash (the measurement's `itp-rs-views-window`, a bench
    /// build), runs in the mode.
    public nonisolated static let viewsWindowTagPrefix = "views-window"
    /// The identifier of the slot the fork puts Views' content view in.
    public nonisolated static let viewsWindowSlotIdentifier = "cmux-views-slot"
    /// The suffix of the runtime class the fork gives an adopted window.
    public nonisolated static let viewsWindowClassSuffix = "_CmuxViews"

    /// Whether the views window switch is on: the environment first, then the build tag.
    public nonisolated static func viewsWindowRequested(tag: String?, environment: [String: String]) -> Bool {
        switch environment[viewsWindowEnvironmentKey] {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return tag.map { $0.hasPrefix(viewsWindowTagPrefix) || $0.contains("-" + viewsWindowTagPrefix) } ?? false
        }
    }

    /// Whether the fork adopted `window` as a Views widget window. Such a window answers `isKind(of:)` for
    /// `NativeWidgetMacNSWindow` while its widget lives, so a rule about Chromium's own windows must skip it.
    public static func isViewsWindowAdopted(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).hasSuffix(viewsWindowClassSuffix)
    }

    /// The key of the fork's `cmuxViewsContainer` associated object (the selector's address, as the fork uses).
    private static let viewsContainerKey = unsafeBitCast(Selector(("cmuxViewsContainer")), to: UnsafeRawPointer.self)

    /// The container `view` itself carries (only a views window page's `WebContentsViewCocoa` carries one).
    public static func viewsContainer(at view: NSView) -> NSView? {
        objc_getAssociatedObject(view, viewsContainerKey) as? NSView
    }

    /// The container that the page holding `view` shows over, or nil when `view` is not in a views window page. The
    /// page's own views are a few levels deep (`RenderWidgetHostViewCocoa` in `WebContentsViewCocoa`).
    public static func viewsContainer(of view: NSView?) -> NSView? {
        var current = view
        var depth = 0
        while let next = current, depth < 6 {
            if let container = viewsContainer(at: next) { return container }
            current = next.superview
            depth += 1
        }
        return nil
    }

    /// The page view (Chromium's `WebContentsViewCocoa`) the fork shows for `container` in its window's slot, or nil
    /// (not views window mode, or no page shown). The page is a few levels under the slot (in Views' content view).
    public static func viewsPage(of container: NSView) -> NSView? {
        guard let root = container.window?.contentView,
              let slot = root.subviews.first(where: { $0 is ViewsWindowSlotView }) else { return nil }
        func find(in view: NSView, depth: Int) -> NSView? {
            if viewsContainer(at: view) === container { return view }
            guard depth < 3 else { return nil }
            return view.subviews.lazy.compactMap { find(in: $0, depth: depth + 1) }.first
        }
        return find(in: slot, depth: 0)
    }

    /// The view that stands for `view` in cmux's own view tree: its page's container for a view of a views window page,
    /// else `view` itself. Use it before asking which pane, chrome region or page holds a responder or a hit.
    public static func anchor(of view: NSView) -> NSView {
        viewsContainer(of: view) ?? view
    }
}

extension NSView {
    /// ``InTreePages/anchor(of:)`` of this view: its views window page's container, else the view itself.
    public var inTreeAnchor: NSView { InTreePages.anchor(of: self) }
}

/// The window's slot for Chromium's Views content view in views window mode (``InTreePages/isViewsWindow``): a clear
/// view that fills the window above the workspace content. The fork adds Views' `BridgedContentView` to it, and that
/// view holds the pages. The slot takes no click of its own: only a page under the pointer takes one.
public final class ViewsWindowSlotView: NSView {
    /// The slot of `view`'s window, made at the first page: in the window's content view, right above its subview
    /// that holds `view` (the workspace content, for a page's container), so the title bar, the sidebar and their
    /// controls stay over the pages. Nil when `view` is in no window.
    @discardableResult
    public static func install(over view: NSView) -> ViewsWindowSlotView? {
        guard let root = view.window?.contentView else { return nil }
        if let slot = root.subviews.lazy.compactMap({ $0 as? ViewsWindowSlotView }).first { return slot }
        var top = view
        while let parent = top.superview, parent !== root { top = parent }
        guard top.superview === root else { return nil }
        let slot = ViewsWindowSlotView(frame: root.bounds)
        root.addSubview(slot, positioned: .above, relativeTo: top)
        return slot
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier(InTreePages.viewsWindowSlotIdentifier)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

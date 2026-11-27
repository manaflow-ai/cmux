public import AppKit
import ObjectiveC

/// Views window mode: approach 3 of the Chromium integration study, "Chromium owns the window"
/// (cmuxterm-hq artifacts/in-tree-pages/approaches/views-window). It is a prototype on top of in-tree pages.
///
/// With the fork's `--cmux-views-window` switch (fork branch cmux/chromium-views-window, CMUX.md "Views window"), the
/// fork adopts the cmux window as a Chromium Views widget window at its first in-tree page. The window's class gets
/// Chromium's widget window protocol (acting only for adopted windows; the window answers `isKind(of:)` for
/// `NativeWidgetMacNSWindow` while its widget lives) and Views' content view goes in the window's ``ViewsWindowSlotView``.
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

    /// Whether the views window switch is on: the environment first, then the build tag.
    public nonisolated static func viewsWindowRequested(tag: String?, environment: [String: String]) -> Bool {
        switch environment[viewsWindowEnvironmentKey] {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return tag.map { $0.hasPrefix(viewsWindowTagPrefix) || $0.contains("-" + viewsWindowTagPrefix) } ?? false
        }
    }

    /// Whether `window`'s own class is `widgetClass` (Chromium's `NativeWidgetMacNSWindow`) or a subclass of it: one of
    /// Chromium's own windows. A window the fork adopted answers `isKind(of:)` for that class while its widget lives,
    /// but its class chain stays cmux's, so a rule about Chromium's windows asks this instead.
    public static func isReally(_ window: NSWindow, kindOf widgetClass: AnyClass) -> Bool {
        var current: AnyClass? = object_getClass(window)
        while let cls = current {
            if cls === widgetClass { return true }
            current = class_getSuperclass(cls)
        }
        return false
    }

    /// Whether the fork adopted `window` as a Views widget window (it answers `isKind(of:)` for `widgetClass` with
    /// a class of its own).
    public static func isViewsWindowAdopted(_ window: NSWindow, widgetClass: AnyClass?) -> Bool {
        guard let widgetClass else { return false }
        return window.isKind(of: widgetClass) && !isReally(window, kindOf: widgetClass)
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
    ///
    /// A page's container joins its window after its page joined the tree when its workspace was made ahead, parked
    /// out of every window: the container installs the slot again when it joins one (`CEFInTreePageView`). If the fork
    /// still found no slot, it put Views' content view on top of the window's content; that view moves into the slot.
    @discardableResult
    public static func install(over view: NSView) -> ViewsWindowSlotView? {
        guard let root = view.window?.contentView else { return nil }
        let slot: ViewsWindowSlotView
        if let found = root.subviews.lazy.compactMap({ $0 as? ViewsWindowSlotView }).first {
            slot = found
        } else {
            var top = view
            while let parent = top.superview, parent !== root { top = parent }
            guard top.superview === root else { return nil }
            slot = ViewsWindowSlotView(frame: root.bounds)
            root.addSubview(slot, positioned: .above, relativeTo: top)
        }
        slot.takeWidgetView(from: root)
        return slot
    }

    /// The class of the fork's view for Views' content view (`CmuxViewsBridgedContentView`, cmux_views_window_mac.mm).
    public nonisolated static let widgetViewClassName = "CmuxViewsBridgedContentView"

    /// Moves the fork's widget view from the window's content view `root` into this slot (the fork found no slot).
    private func takeWidgetView(from root: NSView) {
        for stray in root.subviews where NSStringFromClass(type(of: stray)) == Self.widgetViewClassName {
            stray.removeFromSuperview()
            stray.frame = bounds
            addSubview(stray, positioned: .above, relativeTo: nil)
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier(InTreePages.viewsWindowSlotIdentifier)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { false }

    /// A press in a resize handle's band goes to the handle under the slot: a pane divider's hit area reaches a few
    /// points into the panes beside it, and a page sits over those points (approach 1 puts its divider panels above
    /// its page windows for the same reason, `DividerMouseCatchers`).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let superview, ResizeBands.claims(superview.convert(point, to: nil), in: window) { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

public import AppKit

/// Every scroller in cmux is thin and never a gray track, whatever the macOS
/// "Show scroll bars" setting (SCROLLBARS-THIN, Leo 2026-10-12: "never a
/// permanent gray track"). Native scroll views call `follow(_:)` once and get
/// ``nativeStyle`` (overlay), also after the setting changes; `followThin(_:)`
/// adds the shared ``ThinScroller``. A scroll view with rows and columns (a
/// sideways bar) gets the thin scroller on both axes from `follow(_:)` too: no
/// track on either bar and no fill where they meet (Lawrence 2026-10-23, msg
/// 12114: "do not have extra bg").
/// Pages read `pageValue`, the setting itself: WebKit draws legacy bars for
/// "Always", which the shared web rules (webviews/src/scrollers.ts) thin.
/// The setting is tracked live through
/// `NSScroller.preferredScrollerStyleDidChangeNotification` (one observer,
/// no polling).
@MainActor
public struct SystemScrollers {
    public init() {}
    /// Tests set the system's answer; nil reads `NSScroller.preferredScrollerStyle`.
    public static var preferredStyleOverride: NSScroller.Style?

    public static var preferredStyle: NSScroller.Style { preferredStyleOverride ?? NSScroller.preferredScrollerStyle }

    /// The style of every native scroller: overlay, hidden at rest and shown while scrolling.
    public static let nativeStyle: NSScroller.Style = .overlay

    /// "overlay" or "legacy", for web pages (a root class or theme value).
    public static var pageValue: String { preferredStyle == .legacy ? "legacy" : "overlay" }

    private static var followed: [WeakScrollView] = []
    private static var observers: [Observer] = []
    private static var notifications: Task<Void, Never>?

    /// Gives `scrollView` ``nativeStyle`` now and after every change of the setting (AppKit resets
    /// a scroll view to the system's style then). One that scrolls sideways too gets the shared
    /// ``ThinScroller`` on both bars: AppKit's overlay scrollers paint a track while the pointer is
    /// over them. A table's header corner (the square above the vertical bar) is removed.
    public static func follow(_ scrollView: NSScrollView) {
        if scrollView.hasHorizontalScroller {
            if !(scrollView.horizontalScroller is ThinScroller) { scrollView.horizontalScroller = ThinScroller() }
            if !(scrollView.verticalScroller is ThinScroller) { scrollView.verticalScroller = ThinScroller() }
        }
        (scrollView.documentView as? NSTableView)?.cornerView = nil
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = nativeStyle
        followed.removeAll { $0.value == nil || $0.value === scrollView }
        followed.append(WeakScrollView(scrollView))
        startObserving()
    }

    /// Gives `scrollView` the shared ``ThinScroller`` and follows it like ``follow(_:)``: the
    /// sidebar and every scrollable card (hover cards, the update card's popover) scroll with this
    /// one style, the native twin of the chat's (webviews/src/scrollers.ts).
    public static func followThin(_ scrollView: NSScrollView) {
        if !(scrollView.verticalScroller is ThinScroller) { scrollView.verticalScroller = ThinScroller() }
        follow(scrollView)
    }

    /// The auto-hide of every ``ThinScroller``: true (the default, Lawrence 2026-10-23 msg 11494)
    /// fades its knob out at rest and in while the view scrolls or the pointer nears its edge;
    /// false keeps it shown for as long as the content overflows (Leo 2026-10-21's look).
    public static var thinScrollersAutoHide = true {
        didSet {
            followed.removeAll { $0.value == nil }
            for entry in followed {
                (entry.value?.verticalScroller as? ThinScroller)?.autoHides = thinScrollersAutoHide
                (entry.value?.horizontalScroller as? ThinScroller)?.autoHides = thinScrollersAutoHide
            }
        }
    }

    /// Calls `onChange` with the system's new style on every later change while `owner` lives (the
    /// owner is held weakly). For surfaces that are not a plain NSScrollView: web pages get the
    /// style through their theme payload.
    public static func observe(_ owner: AnyObject, _ onChange: @escaping @MainActor (NSScroller.Style) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, onChange: onChange))
        startObserving()
    }

    private static func startObserving() {
        guard notifications == nil else { return }
        // task-owner: process lifetime (one observer for every scroll view); event-driven.
        notifications = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: NSScroller.preferredScrollerStyleDidChangeNotification) {
                systemStyleDidChange()
            }
        }
    }

    /// Re-applies ``nativeStyle`` to every followed scroll view and tells the observers.
    public static func systemStyleDidChange() {
        followed.removeAll { $0.value == nil }
        let style = preferredStyle
        for entry in followed { entry.value?.scrollerStyle = nativeStyle }
        observers.removeAll { $0.owner == nil }
        for entry in observers { entry.onChange(style) }
    }

    private struct Observer {
        weak var owner: AnyObject?
        let onChange: @MainActor (NSScroller.Style) -> Void
    }

    private struct WeakScrollView {
        weak var value: NSScrollView?
        init(_ value: NSScrollView) { self.value = value }
    }
}


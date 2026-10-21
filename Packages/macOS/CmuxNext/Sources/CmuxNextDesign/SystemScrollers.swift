public import AppKit

/// Every scroller in cmux is thin and shows only while it scrolls, whatever
/// the macOS "Show scroll bars" setting (SCROLLBARS-THIN, Leo 2026-10-12:
/// "never a permanent gray track"). Native scroll views call `follow(_:)`
/// once and get ``nativeStyle`` (overlay), also after the setting changes.
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
    /// a scroll view to the system's style then).
    public static func follow(_ scrollView: NSScrollView) {
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = nativeStyle
        followed.removeAll { $0.value == nil || $0.value === scrollView }
        followed.append(WeakScrollView(scrollView))
        startObserving()
    }

    /// Gives a card's scroll view the shared super-thin ``CardScroller`` and follows it like
    /// ``follow(_:)``: every scrollable card (hover cards, the update card's popover) scrolls with
    /// this one style.
    public static func followAsCard(_ scrollView: NSScrollView) {
        if !(scrollView.verticalScroller is CardScroller) { scrollView.verticalScroller = CardScroller() }
        follow(scrollView)
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


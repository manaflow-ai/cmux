public import AppKit

/// The macOS "Show scroll bars" setting for every scroll surface (R111):
/// "Automatically" or "When scrolling" give overlay scrollers that stay
/// hidden until the user scrolls; "Always" gives legacy scrollers. Native
/// scroll views call `follow(_:)` once and track changes live through
/// `NSScroller.preferredScrollerStyleDidChangeNotification` (one observer,
/// no polling). Pages read `pageValue` from their host.
@MainActor
public struct SystemScrollers {
    public init() {}
    /// Tests set the system's answer; nil reads `NSScroller.preferredScrollerStyle`.
    public static var preferredStyleOverride: NSScroller.Style?

    public static var preferredStyle: NSScroller.Style { preferredStyleOverride ?? NSScroller.preferredScrollerStyle }

    /// "overlay" or "legacy", for web pages (a root class or theme value).
    public static var pageValue: String { preferredStyle == .legacy ? "legacy" : "overlay" }

    private static var followed: [WeakScrollView] = []
    private static var observer: Task<Void, Never>?

    /// Gives `scrollView` the system's scroller style now and on every change.
    public static func follow(_ scrollView: NSScrollView) {
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = preferredStyle
        followed.removeAll { $0.value == nil || $0.value === scrollView }
        followed.append(WeakScrollView(scrollView))
        guard observer == nil else { return }
        // task-owner: process lifetime (one observer for every scroll view); event-driven.
        observer = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: NSScroller.preferredScrollerStyleDidChangeNotification) {
                systemStyleDidChange()
            }
        }
    }

    /// Applies the current style to every followed scroll view.
    public static func systemStyleDidChange() {
        followed.removeAll { $0.value == nil }
        let style = preferredStyle
        for entry in followed { entry.value?.scrollerStyle = style }
    }

    private struct WeakScrollView {
        weak var value: NSScrollView?
        init(_ value: NSScrollView) { self.value = value }
    }
}

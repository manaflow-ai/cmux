public import AppKit

/// Applies the sidebar workspace list's stable overlay-scroller configuration.
///
/// ``SidebarScrollViewResolver`` re-resolves on every SwiftUI update of the
/// sidebar, so ``apply(to:)`` is called repeatedly for the same scroll view —
/// including while AppKit is mid-way through an overlay-scroller fade. Any
/// write to these properties (even with an unchanged value) re-tiles the
/// scrollers and can cancel the in-flight fade without rescheduling it,
/// stranding the knob permanently visible (#3241 follow-up).
public enum SidebarScrollViewConfigurator {
    /// Forces the scroll view into the stable overlay-scroller configuration,
    /// writing each property only when it differs to avoid cancelling an
    /// in-flight scroller fade.
    ///
    /// `@MainActor` because it reads and mutates `NSScrollView`'s
    /// main-actor-isolated scroller properties; every caller (the resolver's
    /// `onResolve` callback, driven from the main thread) is already on the main
    /// actor.
    @MainActor
    public static func apply(to scrollView: NSScrollView) {
        if scrollView.hasHorizontalScroller {
            scrollView.hasHorizontalScroller = false
        }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if !scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = true
        }
    }
}

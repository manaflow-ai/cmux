import AppKit

/// Applies the sidebar workspace list's stable overlay-scroller configuration.
///
/// `SidebarScrollViewResolver` re-resolves on every SwiftUI update of the
/// sidebar, so `apply(to:)` is called repeatedly for the same scroll view —
/// including while AppKit is mid-way through an overlay-scroller fade. Any
/// write to these properties (even with an unchanged value) re-tiles the
/// scrollers and can cancel the in-flight fade without rescheduling it,
/// stranding the knob permanently visible (#3241 follow-up).
enum SidebarScrollViewConfigurator {
    static func apply(to scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
    }
}

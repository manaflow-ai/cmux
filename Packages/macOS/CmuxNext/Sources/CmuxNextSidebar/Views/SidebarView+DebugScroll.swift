#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

extension SidebarView {
    /// The workspace list's scroll view (`debug.scroll_frames`).
    public var debugListScrollView: NSScrollView { scrollView }
}
#endif

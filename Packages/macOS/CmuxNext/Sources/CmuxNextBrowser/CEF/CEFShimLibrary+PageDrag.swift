import Foundation

nonisolated extension CEFShimLibrary {
    /// `cmux_shim_set_drag_source_handler`'s fn: ctx, browser, the fork's `cmux_drag_source_t` (valid during the call).
    typealias DragSourceFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?) -> Void

    /// A page's drag out of its page and back over it (fork API 30; task p01-process-051 of
    /// plans/cmux-next/chrome-parity/p01-process.md). Each returns 0 for an unknown browser, or on a fork without
    /// the drag source API (the shim then keeps Chromium's own drag session). In host mode they are the remote
    /// shim's: the handler is its local class's (remote_shim_local.mm), the rest are posts.
    struct PageDrag {
        /// `cmux_shim_set_drag_source_handler(fn, ctx)`: a page's drags go to fn instead of a session of its own
        /// window; nil restores that.
        let setSourceHandler: @convention(c) (DragSourceFn?, UnsafeMutableRawPointer?) -> Void
        /// `cmux_shim_browser_drag_source_ended(browser, x, y, screen x, screen y, operation)`.
        let sourceEnded: @convention(c) (Int32, Double, Double, Double, Double, Int32) -> Int32
        /// `cmux_shim_browser_drag_target_enter_source(browser, x, y, allowed, modifiers)`: back over its page.
        let targetEnterSource: @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32
        /// `cmux_shim_browser_drag_target_over(browser, x, y, allowed, modifiers)`.
        let targetOver: @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32
        /// `cmux_shim_browser_drag_target_leave(browser)`.
        let targetLeave: @convention(c) (Int32) -> Int32
        /// `cmux_shim_browser_drag_target_drop(browser, x, y, modifiers)`.
        let targetDrop: @convention(c) (Int32, Int32, Int32, Int32) -> Int32

        init(_ r: Resolver) throws(LoadError) {
            setSourceHandler = try r("cmux_shim_set_drag_source_handler")
            sourceEnded = try r("cmux_shim_browser_drag_source_ended")
            targetEnterSource = try r("cmux_shim_browser_drag_target_enter_source")
            targetOver = try r("cmux_shim_browser_drag_target_over")
            targetLeave = try r("cmux_shim_browser_drag_target_leave")
            targetDrop = try r("cmux_shim_browser_drag_target_drop")
        }
    }
}

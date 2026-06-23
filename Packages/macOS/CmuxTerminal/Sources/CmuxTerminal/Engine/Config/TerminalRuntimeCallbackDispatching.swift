public import GhosttyKit

/// The hot-path / app-coupled runtime-callback surface the cold engine runtime
/// forwards to but does NOT own.
///
/// The runtime owns engine initialization and the `app`/`config` handles, but
/// the live `ghostty_runtime_config_s` callbacks are either LATENCY-CRITICAL or
/// deeply app-coupled and stay INLINE in the app-target `GhosttyApp` per the
/// hot-path fence:
/// - `wakeup_cb` coalesces I/O-thread wakeups into the per-frame tick loop.
/// - `action_cb` dispatches every `ghostty_action_s` (render/scrollbar/cell-size
///   hot actions included) through `handleAction`.
/// - the clipboard/close callbacks reach `AppDelegate`, the terminal pasteboard,
///   the surface registry, and the tab manager.
///
/// So the runtime asks the host to build the full callback table
/// (``makeRuntimeConfig()``, every callback wired except `userdata`), sets
/// `userdata` to itself, and runs `ghostty_app_new`. The wakeup/action C
/// callbacks resolve the runtime from `userdata` and forward here so the hot
/// tick loop and `handleAction` keep living in the god.
///
/// Isolation: the callbacks fire on Ghostty's I/O / runtime threads, so the
/// builder and the dispatch members are `nonisolated` and the conformer is
/// `Sendable`.
public protocol TerminalRuntimeCallbackDispatching: AnyObject, Sendable {
    /// Returns a fully-populated `ghostty_runtime_config_s` with every cmux
    /// callback wired EXCEPT `userdata`, which the runtime sets to the live
    /// engine instance immediately before `ghostty_app_new`.
    func makeRuntimeConfig() -> ghostty_runtime_config_s

    /// Coalesces a Ghostty wakeup into a pending main-queue tick (was
    /// `wakeup_cb { runtimeApp.scheduleTick() }`).
    func dispatchWakeup()

    /// Dispatches a Ghostty action to the host (was
    /// `action_cb { runtimeApp.handleAction(target:action:) }`).
    func dispatchAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool
}

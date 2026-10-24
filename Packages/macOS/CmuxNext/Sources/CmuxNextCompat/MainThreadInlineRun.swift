public import Foundation

/// Main-actor work that a `nonisolated` caller runs inline when it is already on the main thread.
///
/// It replaces the hand-written `if Thread.isMainThread { MainActor.assumeIsolated { ... } }` in a
/// `nonisolated deinit` (an isolated deinit's runtime hop traps when the object is released inside
/// an action's task-local scope, cx-t7hu): the main-thread proof lives here once. AppKit releases
/// its views on the main thread, so a view's main-actor stops run there and then, before the next
/// line of the releasing code; the caller handles the rare release off main itself, for example
/// with a `Task { @MainActor in ... }` over the Sendable handles it copied.
///
/// ```swift
/// nonisolated deinit {
///     if MainThreadInlineRun.ifOnMainThread({ transcript.stop() }) { return }
///     let transcript = transcript
///     Task { @MainActor in transcript.stop() }
/// }
/// ```
public nonisolated struct MainThreadInlineRun {
    /// Runs `body` on the main actor, synchronously, when the caller is on the main thread.
    ///
    /// - Parameter body: The main-actor work. It runs at most once, before this returns.
    /// - Returns: `true` when `body` ran (the caller is on the main thread); `false` when the
    ///   caller is on another thread and `body` did not run.
    @discardableResult
    public static func ifOnMainThread(_ body: @MainActor () -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        MainActor.assumeIsolated { body() } // main-proof: checked Thread.isMainThread above
        return true
    }
}

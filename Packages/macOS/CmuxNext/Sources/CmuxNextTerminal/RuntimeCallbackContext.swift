import CmuxNextCompat
import CmuxNextWakeups

/// Runtime-level callback userdata. Collapses bursts of `wakeup_cb` (any thread, which touches
/// only the atomic flags) into one main-actor tick and points back at the runtime (main-actor only).
/// libghostty gets its ``callbacks`` token, never its address, so a callback
/// that comes after the context is gone finds nothing instead of reading freed memory (Chromium's
/// MiraclePtr goal, base/allocator/partition_allocator/src/partition_alloc/pointers/raw_ptr.h).
nonisolated final class RuntimeCallbackContext: Sendable {
    /// A tick is wanted and one is coming: a hop to main, or the next frame while ``framed``.
    let pending = Atomic<Bool>(false)
    /// The runtime's frame client looks at ``pending`` on each frame (``GhosttyTickPacer``): a wakeup
    /// then needs no hop to main.
    let framed = Atomic<Bool>(false)
    @MainActor weak var runtime: GhosttyRuntime?

    /// Notes a wakeup from any thread; true when the caller must hop to main to run the tick. The
    /// first wakeup of a burst hops, unless the frame client will see it; the rest merge into it.
    /// Both atomics are sequentially consistent, as the client's stop is (``GhosttyTickPacer``): a
    /// wakeup sees the client stopped, or the stopping client sees the wakeup.
    // perf-hot: 0.05us terminal-feed
    func wake() -> Bool {
        guard pending.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged else {
            return false
        }
        return !framed.load(ordering: .sequentiallyConsistent)
    }

    /// Queues the hop ``wake()`` asked for, from any thread: the runtime's
    /// ``GhosttyRuntime/wakeupArrived(posted:)`` on a later pass of the main run loop.
    ///
    /// - Parameter post: When the wakeup came.
    func hopToMain(posted post: MainTaskPost) {
        MainRunLoopBlock.perform { self.runtime?.wakeupArrived(posted: post) }
    }

    /// The started runtimes' contexts by the token each gives libghostty as its userdata. A C
    /// callback gets nothing but that userdata, so it reaches this table by name, as
    /// FolderWatchStream's callback reaches its own.
    static let callbacks = CallbackRegistry<RuntimeCallbackContext>(capacity: 64)

    /// The context behind the runtime's userdata (`ghostty_runtime_config_s.userdata`, its
    /// ``callbacks`` token): nil for nil, an unknown or stale token or a context that is gone
    /// (counted). `wakeup_cb` runs it on every output burst, from any thread: one lock-free slot read.
    // perf-hot: 0.05us terminal-feed
    static func from(_ raw: UnsafeMutableRawPointer?) -> RuntimeCallbackContext? {
        // SAFETY: only the token's bits are read; the registry resolves them or ignores them.
        unsafe callbacks.target(forContext: raw)
    }
}

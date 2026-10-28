import CmuxNextCompat

/// Runtime-level callback userdata. Collapses bursts of `wakeup_cb` (any thread, which touches
/// only the atomic flag) into one main-actor tick and points back at the runtime (main-actor only).
/// libghostty gets its ``callbacks`` token, never its address (p10-stability-082), so a callback
/// that comes after the context is gone finds nothing instead of reading freed memory (Chromium's
/// MiraclePtr goal, base/allocator/partition_allocator/src/partition_alloc/pointers/raw_ptr.h).
nonisolated final class RuntimeCallbackContext: Sendable {
    let pending = Atomic<Bool>(false)
    @MainActor weak var runtime: GhosttyRuntime?

    /// The started runtimes' contexts by the token each gives libghostty as its userdata. A C
    /// callback gets nothing but that userdata, so it reaches this table by name, as
    /// FolderWatchStream's callback reaches its own (p10-stability-081).
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

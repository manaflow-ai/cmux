import CmuxNextCompat

/// The shim's callback contexts: every C callback gets the runtime's ``CallbackRegistry``
/// token, never the runtime's address, so a callback that comes after the runtime is gone finds nothing
/// instead of reading freed memory (Chromium's MiraclePtr goal for raw pointers,
/// base/allocator/partition_allocator/src/partition_alloc/pointers/raw_ptr.h).
extension CEFRuntime {
    /// The started runtimes by the token each gives the shim as every callback's context (``from(_:)``). A C
    /// callback gets nothing but that context, so it reaches this table by name, as FolderWatchStream's
    /// callback reaches its own; it holds this type's entries only.
    nonisolated static let callbacks = CallbackRegistry<CEFRuntime>(capacity: 8)

    /// The runtime behind a callback context, its ``callbacks`` token: nil for 0, an unknown or stale token
    /// or a runtime that is gone (the registry counts those), never a freed object.
    static func from(_ address: UInt) -> CEFRuntime? {
        // SAFETY: only the token's bits; the registry resolves them (a lock-free slot read) or ignores them.
        unsafe callbacks.target(forContext: UnsafeMutableRawPointer(bitPattern: address))
    }

    /// The pump's cross-thread gate behind a callback context, from any thread (a `nonisolated let`
    /// of the runtime the token names).
    nonisolated static func pumpGate(at address: UInt) -> CEFPumpCrossThreadGate? {
        // SAFETY: as for `from(_:)`; only the runtime's `nonisolated let` gate is read.
        unsafe callbacks.target(forContext: UnsafeMutableRawPointer(bitPattern: address))?.pumpGate
    }
}

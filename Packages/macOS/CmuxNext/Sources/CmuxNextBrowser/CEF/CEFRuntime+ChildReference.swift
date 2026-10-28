import struct CmuxSafeConcurrency.OwnerReference

extension CEFRuntime {
    /// A child's non-owning reference to the runtime that owns it (its extension stores, prompts and backends, its
    /// orphan list). The app's runtime is never freed, a test's can go before its children: a
    /// read then reports `cef-runtime-outlives-its-children` once per site and the child does nothing.
    static func childReference(_ runtime: CEFRuntime) -> OwnerReference<CEFRuntime> {
        OwnerReference(runtime, invariant: "cef-runtime-outlives-its-children")
    }
}

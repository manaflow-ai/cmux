/// Reads and writes the crash-key page's slots (``CrashKeySlot``): ``TraceRuntime`` is the one
/// implementation (the app passes `TraceRuntime.shared` from its composition root). The protocol exists so
/// a writer (the CEF pump, the hang monitor) takes it by `init` and a test passes a recording fake.
///
/// Both calls are a relaxed atomic store or load of a preallocated word: no lock, no allocation, so a
/// thread may call them while another thread is suspended for a stack sample, as Chrome's crash keys
/// (components/crash/core/common/crash_key.h) are set and read with no allocation.
public protocol CrashKeyStore: Sendable {
    /// Stores `value` in `slot`.
    func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64)
    /// The value `slot` holds now (0 when never set).
    func crashKey(_ slot: CrashKeySlot) -> UInt64
}

extension TraceRuntime: CrashKeyStore {}

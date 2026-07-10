/// Transports an otherwise non-`Sendable` value across the actor/queue boundary.
/// Sound here because the iroh FFI handles are process-global registry keys, not
/// raw addresses: every blocking call holds its own reference, and close is safe
/// to call concurrently (see cmux_iroh_ffi.h), so passing a handle to a
/// background queue and racing close against it can never use freed memory.
struct CmxIrohUnsafeBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Result of a fallible FFI call: the body's return plus the parsed error.
/// Conditionally `Sendable` so outcomes carrying a `Sendable` result (e.g. the
/// `Int32` send status) can cross the actor/queue continuation boundary.
struct CmxIrohCallOutcome<R> {
    let result: R
    let errorKind: Int32
    let message: String
}

extension CmxIrohCallOutcome: Sendable where R: Sendable {}

/// The parsed result of a single `recv` call, carried back across the
/// actor/queue continuation boundary.
struct CmxIrohReceiveOutcome: Sendable {
    let count: Int
    let message: String
    let buffer: [UInt8]
}

public import XPC

/// Explicit ownership wrapper for XPC objects crossing Swift concurrency
/// boundaries.
///
/// XPC objects are reference-counted and their documented connection send
/// operations are thread-safe. Message dictionaries are immutable after they
/// enter this wrapper.
public final class RendererXPCObject: @unchecked Sendable {
    public let value: xpc_object_t

    public init(_ value: xpc_object_t) {
        self.value = value
    }
}

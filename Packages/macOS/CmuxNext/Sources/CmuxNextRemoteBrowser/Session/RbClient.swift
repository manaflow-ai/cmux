import CCmuxRdFFI
public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// Why the client reducer refused a call.
public nonisolated enum RbClientError: Error, Sendable, Hashable {
    /// The input is not a client input (the state did not change).
    case invalid
    /// The reducer panicked; this client is unusable.
    case poisoned
    /// The outcome was not the documented JSON shape.
    case malformedOutcome
    case code(Int32)
}

/// The viewer's reducer of one remote tab (`cmux.rb/1`), implemented by the
/// shared Rust core (cmux-rd-ffi `CmuxRbClient` over
/// cmux-remote-browser `client::Client`). Host messages and the person's
/// answers go in; effects (native menus, sheets, cursor, page state,
/// messages for the host) come out. JSON in the shapes of
/// schemas/remote-tab/client.json. No I/O; not thread-safe: one actor owns
/// an instance.
public nonisolated final class RbClient {
    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate a client.
    public init?() {
        // The rb client C ABI exists from ABI 2 on; an older static library
        // would fail to link, so this only guards a mismatched header.
        assert(RemoteRdCore.abiVersion >= 2, "CCmuxAppFFI predates the rb client ABI (needs ABI 2)")
        guard let handle = cmux_rb_client_new() else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rb_client_free(handle)
    }

    /// Applies one input and returns its outcome. A refused input
    /// (`outcome.reject`) leaves the state unchanged.
    public func apply(_ input: RbClientInput) throws(RbClientError) -> RbClientOutcome {
        guard let json = try? JSONEncoder().encode(input.json) else { throw .invalid }
        var outcome: UnsafePointer<UInt8>?
        var length = 0
        let code = json.withUnsafeBytes { raw in
            cmux_rb_client_apply(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &outcome, &length)
        }
        switch code {
        case 0: break
        case -2: throw .invalid
        case -6: throw .poisoned
        default: throw .code(code)
        }
        guard let outcome else { throw .malformedOutcome }
        let bytes = Data(bytes: outcome, count: length)
        guard let decoded = try? Self.decoder.decode(RbClientOutcome.self, from: bytes) else { throw .malformedOutcome }
        return decoded
    }

    /// Plain keys: `send` bodies are host messages and keep their names.
    private static let decoder = JSONDecoder()
}
#endif

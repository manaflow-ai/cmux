internal import CCmuxAuthCoordinatorFFI
public import CmuxAuthRuntime
public import Foundation

/// The Rust auth reducer through the app's C ABI (`cmux_auth_coordinator_*`, CCmuxAppFFI).
/// ``AuthCoordinator`` uses it on the main actor only.
public final class AuthReducerFFI: AuthReducerEngine {
    struct CallFailed: Error { let code: Int32 }

    private let handle: OpaquePointer

    /// The factory ``AuthCoordinator`` takes.
    public static let factory: AuthReducerFactory = { try AuthReducerFFI(config: $0) }

    public init(config: Data) throws {
        var out: OpaquePointer?
        let code = config.withUnsafeBytes { raw in
            cmux_auth_coordinator_new(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        guard code == CMUX_AUTH_COORDINATOR_OK, let out else { throw CallFailed(code: code) }
        handle = out
    }

    deinit { cmux_auth_coordinator_free(handle) }

    public func feed(_ event: Data) throws {
        let code = event.withUnsafeBytes { raw in
            cmux_auth_coordinator_feed(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard code == CMUX_AUTH_COORDINATOR_OK else { throw CallFailed(code: code) }
    }

    public func takeEffects() -> Data { read(cmux_auth_coordinator_take_effects) ?? Data("[]".utf8) }

    public func snapshot() -> Data { read(cmux_auth_coordinator_snapshot) ?? Data("{}".utf8) }

    private func read(_ call: (OpaquePointer?, UnsafeMutablePointer<CmuxAuthCoordinatorBytes>?) -> Int32) -> Data? {
        var bytes = CmuxAuthCoordinatorBytes(ptr: nil, len: 0)
        guard call(handle, &bytes) == CMUX_AUTH_COORDINATOR_OK else { return nil }
        defer { cmux_auth_coordinator_bytes_free(bytes) }
        guard let ptr = bytes.ptr else { return Data() }
        return Data(bytes: ptr, count: bytes.len)
    }
}

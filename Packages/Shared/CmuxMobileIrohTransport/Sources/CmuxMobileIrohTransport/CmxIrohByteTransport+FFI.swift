import Foundation
import OSLog
internal import CmuxIrohFFI

// Low-level CmuxIrohFFI bridging, scoped onto the transport that owns it rather
// than as free functions. Several are `static` because they run before an
// endpoint exists (key generation) or inside the actor's background queue
// closures (the error-buffer and C-string marshalling shims).
extension CmxIrohByteTransport {
    static let diagnosticLogger = Logger(subsystem: "dev.cmux", category: "mobile-iroh")

    /// Length in bytes of an iroh Ed25519 secret key (CMUX_IROH_SECRET_KEY_LEN).
    static let secretKeyLength = 32

    /// Generates a fresh 32-byte iroh secret key, or nil on failure.
    static func generateSecretKey() -> [UInt8]? {
        var key = [UInt8](repeating: 0, count: secretKeyLength)
        let rc = key.withUnsafeMutableBufferPointer { buffer in
            cmux_iroh_secret_key_generate(buffer.baseAddress, buffer.count)
        }
        return rc == 0 ? key : nil
    }

    /// Reads a heap C string returned by the FFI and frees it.
    static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { cmux_iroh_string_free(pointer) }
        return String(cString: pointer)
    }

    /// Runs `body` with a fresh `(err_kind, err_buf, err_cap)` triple and parses
    /// the error out-params afterward.
    static func withErrorBuffer<R>(
        _ body: (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>, Int) -> R
    ) -> CmxIrohCallOutcome<R> {
        var kind: Int32 = 0
        let capacity = 256
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: capacity)
        let result = withUnsafeMutablePointer(to: &kind) { kindPointer in
            body(kindPointer, buffer, capacity)
        }
        return CmxIrohCallOutcome(result: result, errorKind: kind, message: String(cString: buffer))
    }

    /// Dials `endpointID` over `endpoint`, returning the connection or nil.
    static func dialConnection(
        _ endpoint: OpaquePointer,
        endpointID: String,
        relayURL: String?,
        directAddrs: [String],
        relayOnly: Bool,
        timeoutMs: UInt64,
        _ errKind: UnsafeMutablePointer<Int32>,
        _ errBuffer: UnsafeMutablePointer<CChar>,
        _ errCapacity: Int
    ) -> OpaquePointer? {
        endpointID.withCString { idC in
            withOptionalCString(relayURL) { relayC in
                withCStringArray(directAddrs) { addrsPointer, addrCount in
                    if relayOnly {
                        cmux_iroh_endpoint_connect_relay_only(
                            endpoint,
                            idC,
                            relayC,
                            addrsPointer,
                            addrCount,
                            timeoutMs,
                            errKind,
                            errBuffer,
                            errCapacity
                        )
                    } else {
                        cmux_iroh_endpoint_connect(
                            endpoint,
                            idC,
                            relayC,
                            addrsPointer,
                            addrCount,
                            timeoutMs,
                            errKind,
                            errBuffer,
                            errCapacity
                        )
                    }
                }
            }
        }
    }

    static func pathKindName(_ rawValue: Int32) -> String {
        switch rawValue {
        case 1: "relay"
        case 2: "direct"
        case 3: "mixed"
        default: "unknown"
        }
    }

    /// Calls `body` with `string` as a C string, or nil when `string` is nil.
    /// Internal so the host listener's bind path can reuse the same optional
    /// relay-URL bridging the dialer uses.
    static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> R
    ) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }

    /// Calls `body` with a `const char *const *` view of `strings` and its
    /// count. The pointers are valid only for the duration of `body`.
    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> R
    ) -> R {
        let duplicates: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { for pointer in duplicates { free(pointer) } }
        let constants: [UnsafePointer<CChar>?] = duplicates.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        return constants.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}

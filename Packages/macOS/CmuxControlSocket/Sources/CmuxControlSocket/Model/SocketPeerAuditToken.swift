public import Darwin

/// The immutable audit token of one accepted Unix-domain-socket peer.
///
/// Unlike a PID, the token includes the kernel PID version. A later process
/// that reuses the PID, or the same process after `exec(2)`, has a different
/// token and cannot reuse this value as process identity.
public struct SocketPeerAuditToken: Sendable, Equatable, Hashable {
    /// The byte size of Darwin's `audit_token_t` on this platform.
    public static let byteCount = MemoryLayout<audit_token_t>.size

    /// An immutable copy of the kernel token bytes.
    public let bytes: [UInt8]

    /// Creates a token from an exact `audit_token_t` byte representation.
    ///
    /// - Parameter bytes: Exactly ``byteCount`` native-endian bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// The process ID encoded by the kernel in this audit token.
    public var processID: pid_t {
        pid_t(bitPattern: nativeUInt32(at: 5))
    }

    /// The PID-version value that prevents PID-reuse confusion.
    public var processVersion: UInt32 {
        nativeUInt32(at: 7)
    }

    /// Effective UID encoded by the kernel.
    public var effectiveUserID: uid_t {
        uid_t(nativeUInt32(at: 1))
    }

    /// Real UID encoded by the kernel.
    public var realUserID: uid_t {
        uid_t(nativeUInt32(at: 3))
    }

    private func nativeUInt32(at index: Int) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            buffer.loadUnaligned(
                fromByteOffset: index * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )
        }
    }
}

/// The kernel process launch time used with an audit token to reject PID reuse.
public struct SocketPeerProcessStartTime: Sendable, Equatable, Hashable {
    /// Continuous absolute-time launch value from `ri_proc_start_abstime`.
    public let absoluteTime: UInt64

    public init(absoluteTime: UInt64) {
        self.absoluteTime = absoluteTime
    }
}

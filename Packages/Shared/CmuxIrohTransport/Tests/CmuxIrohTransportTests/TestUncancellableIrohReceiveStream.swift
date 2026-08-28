import Foundation
@testable import CmuxIrohTransport

/// A control stream whose pending read ignores Swift task cancellation
/// entirely, mirroring the FFI driver contract: the generated bindings
/// suspend the caller on a polled Rust future that `Task.cancel()` never
/// touches. Only a transport-boundary abort (`failPendingReceives`, wired
/// to connection close in tests) terminates the read.
actor TestUncancellableIrohReceiveStream: CmxIrohReceiveStream {
    private var pendingReceives: [CheckedContinuation<Data?, any Error>] = []
    private var failed = false

    func receive(maximumByteCount _: Int) async throws -> Data? {
        guard !failed else { throw TestIrohTransportError.unsupported }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceives.append(continuation)
        }
    }

    func stop(errorCode _: UInt64) {}

    /// Models the QUIC semantics of closing the owning connection: every
    /// pending and future stream read fails immediately.
    func failPendingReceives() {
        failed = true
        let pending = pendingReceives
        pendingReceives = []
        for continuation in pending {
            continuation.resume(throwing: TestIrohTransportError.unsupported)
        }
    }
}

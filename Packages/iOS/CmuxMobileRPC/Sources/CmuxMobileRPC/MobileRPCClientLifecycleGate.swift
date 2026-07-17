internal import CMUXMobileCore
internal import Foundation

/// Linearizes new transport ownership against synchronous client retirement.
final class MobileRPCClientLifecycleGate: @unchecked Sendable {
    struct IndependentEventAdmission: Sendable {
        fileprivate let revision: UInt64
    }

    // Safety: every mutable field is accessed only while `lock` is held.
    private let lock = NSLock()
    private var retired = false
    private var revision: UInt64 = 0

    func makeTransport<T>(_ make: () throws -> T) throws -> T {
        try lock.withLock {
            guard !retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            return try make()
        }
    }

    func beginIndependentEventAdmission() throws -> IndependentEventAdmission {
        try lock.withLock {
            guard !retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            return IndependentEventAdmission(revision: revision)
        }
    }

    func finishIndependentEventAdmission(
        _ admission: IndependentEventAdmission,
        stream: CmxIndependentEventByteStream
    ) async throws -> CmxIndependentEventByteStream {
        let accepted = lock.withLock {
            !retired && revision == admission.revision
        }
        guard accepted else {
            await Self.dispose(stream)
            throw MobileShellConnectionError.connectionClosed
        }
        return stream
    }

    func retire() {
        lock.withLock {
            retired = true
            revision &+= 1
        }
    }

    private static func dispose(_ stream: CmxIndependentEventByteStream) async {
        let drain = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the disposal mechanism for the abandoned stream.
            }
        }
        drain.cancel()
        _ = await drain.result
    }
}

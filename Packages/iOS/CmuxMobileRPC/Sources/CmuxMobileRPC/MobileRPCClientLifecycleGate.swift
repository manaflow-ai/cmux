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

    func makeTransport(
        _ make: () throws -> any CmxByteTransport
    ) throws -> any CmxByteTransport {
        let admission = try lock.withLock {
            guard !retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            return revision
        }
        let transport = try make()
        let accepted = lock.withLock {
            !retired && revision == admission
        }
        guard accepted else {
            Self.dispose(transport)
            throw MobileShellConnectionError.connectionClosed
        }
        return transport
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

    private static func dispose(_ transport: any CmxByteTransport) {
        Task.detached {
            await transport.close()
        }
    }
}

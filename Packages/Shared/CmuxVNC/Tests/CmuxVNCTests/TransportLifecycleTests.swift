import Foundation
import Testing
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
@testable import CmuxVNC

/// The transport's open/close state lives in CmuxThreading's Mutex (no NSLock). These pin that an
/// open resumes exactly once, whichever of the connection state or a close comes first.
struct TransportLifecycleTests {
    @Test func aReadyConnectionResumesTheOpen() async throws {
        let lifecycle = TransportLifecycle()
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            #expect(lifecycle.beginOpen(continuation))
            lifecycle.finishOpen(nil)
        }
        // A later close finds no open to resume.
        lifecycle.close()
    }

    @Test func aCloseFailsTheWaitingOpen() async {
        let lifecycle = TransportLifecycle()
        await #expect(throws: RFBError.connectionClosed) {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                #expect(lifecycle.beginOpen(continuation))
                lifecycle.close()
                // The connection's late state change resumes nothing a second time.
                lifecycle.finishOpen(nil)
            }
        }
    }

    @Test func anOpenAfterACloseFailsAtOnce() async {
        let lifecycle = TransportLifecycle()
        lifecycle.close()
        await #expect(throws: RFBError.connectionClosed) {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                #expect(!lifecycle.beginOpen(continuation))
            }
        }
    }
}

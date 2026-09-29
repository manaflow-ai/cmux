import CMUXMobileCore
import Foundation
import os

/// One terminal outcome shared by the native task and its lifecycle owner.
final class MobileRPCTransportDialDiagnostics: Sendable {
    private let id = Int.random(in: 1...Int.max)
    private let startedAt = ContinuousClock.now
    private let transport: DiagnosticTransportKind?
    private let observer: MobileCoreRPCSession.TransportConnectObserver?
    // A short synchronous compare-and-set arbitrates native completion,
    // cancellation and deinit; it holds no transport or mutable domain state.
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(
        transport: DiagnosticTransportKind?,
        observer: MobileCoreRPCSession.TransportConnectObserver?
    ) {
        self.transport = transport
        self.observer = observer
        if let transport { observer?(.attempt(attemptID: id, transport: transport)) }
    }

    func connected(sessionID: Int?) {
        finish { transport, elapsed in
            .connected(attemptID: id, transport: transport, elapsedMilliseconds: elapsed, sessionID: sessionID)
        }
    }

    func failed(_ failure: DiagnosticFailureKind) {
        finish { transport, elapsed in
            .failed(attemptID: id, transport: transport, failure: failure, elapsedMilliseconds: elapsed)
        }
    }

    func cancelled(_ reason: DiagnosticCancellationReason) {
        finish { transport, elapsed in
            .cancelled(attemptID: id, transport: transport, reason: reason, elapsedMilliseconds: elapsed)
        }
    }

    private func finish(_ event: (DiagnosticTransportKind, Int) -> MobileRPCTransportConnectEvent) {
        let won = finished.withLock { terminal in
            guard !terminal else { return false }
            terminal = true
            return true
        }
        guard won, let transport, let observer else { return }
        let elapsed = startedAt.duration(to: .now).components
        let milliseconds = max(0, Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
        observer(event(transport, milliseconds))
    }
}

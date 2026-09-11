import Dispatch
import Foundation

/// Bridges the kernel process-exit notification source to an ``AsyncStream``.
struct SudoProcessExitObserver: SudoProcessExitObserving, Sendable {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    func events(for identity: SudoProcessIdentity) -> AsyncStream<Void> {
        AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard identity.processIdentifier > 1 else {
                continuation.yield(())
                continuation.finish()
                return
            }
            guard inspector.isRunning(identity) else {
                continuation.yield(())
                continuation.finish()
                return
            }

            // DispatchSource is the macOS process-exit bridge; it avoids a
            // polling loop and is cancelled when the consuming task ends.
            let source = DispatchSource.makeProcessSource(
                identifier: identity.processIdentifier,
                eventMask: .exit,
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                guard inspector.identity(for: identity.processIdentifier) != identity else {
                    return
                }
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()

            // Close the registration race without accepting a reused PID.
            if inspector.identity(for: identity.processIdentifier) != identity {
                source.cancel()
                continuation.yield(())
                continuation.finish()
            }
        }
    }
}

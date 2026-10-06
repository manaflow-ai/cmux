import Foundation

/// The viewer's side of the `cmux.rd/1` session setup, as a pure reducer:
/// hello and start go out, then the host answers welcome and started (or
/// refused); ended closes the session. Every other order is a protocol error
/// and ends the session.
public nonisolated struct RemoteRdHandshake: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case awaitingWelcome
        case awaitingStarted
        case streaming(session: UInt64)
        case ended(RemoteSessionEnd)
    }

    public private(set) var phase: Phase = .awaitingWelcome
    public private(set) var welcome: RemoteRdWelcome?
    /// The service the hello asked for; welcome must name the same one.
    public let service: String
    /// True after the viewer sent stop: the host's ended then means "stopped by viewer".
    public private(set) var stopSent = false

    public init(service: String) {
        self.service = service
    }

    /// The pane-facing state of the current phase.
    public var sessionState: RemoteSessionState {
        switch phase {
        case .awaitingWelcome, .awaitingStarted: .connecting
        case .streaming: .streaming
        case let .ended(end): .ended(end)
        }
    }

    public var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// Applies one control message from the host.
    public mutating func receive(_ control: RemoteRdControl) {
        guard !isEnded else { return }
        switch (phase, control) {
        case let (.awaitingWelcome, .welcome(welcome)):
            // A host older than C1 omits the service; a mismatch is a protocol error.
            if let routed = welcome.service, routed != service {
                phase = .ended(.connectionLost)
                return
            }
            self.welcome = welcome
            phase = .awaitingStarted
        case let (.awaitingStarted, .started(session)):
            phase = .streaming(session: session)
        case (_, .refused):
            phase = .ended(.consentDenied)
        case (_, .ended):
            phase = .ended(stopSent ? .stoppedByViewer : .hostStoppedSharing)
        case (_, .stats), (_, .unknown):
            break
        default:
            phase = .ended(.connectionLost)
        }
    }

    /// The viewer sent stop.
    public mutating func viewerStopped() {
        stopSent = true
    }

    /// The carrier closed or failed.
    public mutating func connectionClosed() {
        guard !isEnded else { return }
        phase = .ended(stopSent ? .stoppedByViewer : .connectionLost)
    }
}

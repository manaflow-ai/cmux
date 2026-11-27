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
        case let (_, .ended(reason)):
            phase = .ended(stopSent ? .stoppedByViewer : Self.hostEnd(reason))
        case (_, .stats), (_, .unknown), (_, .service), (_, .bulkCredit), (_, .streamOpen),
             (_, .streamOpened), (_, .streamRefused), (_, .streamClose):
            // Service, bulk and stream messages go to their handlers, not the setup.
            break
        default:
            phase = .ended(.connectionLost)
        }
    }

    /// What the host's `ended` means: `cmux rd serve` ends a session it could not run with
    /// `failed: <error>` (cmux-rd-host `serve.rs`), and that error is kept for the card; any
    /// other reason (stopped, the viewer left) is the host stopping.
    public static func hostEnd(_ reason: String) -> RemoteSessionEnd {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "failed" || text.hasPrefix("failed:") else { return .hostStoppedSharing }
        return .hostFailed(reason: String(text.dropFirst("failed".count).drop { $0 == ":" || $0 == " " }))
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

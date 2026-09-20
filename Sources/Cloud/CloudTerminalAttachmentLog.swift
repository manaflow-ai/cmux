import Foundation
import os

/// Durable, privacy-safe evidence for the cloud terminal attachment path.
///
/// Every decision this path makes lands in the unified log in release builds
/// (subsystem `com.cmuxterm.app`, category `CloudTerminalAttachment`), so a
/// report can say which terminal, which phase, and what the daemon answered.
/// Machine and terminal ids are public; daemon text that could
/// carry a path or a command line stays private.
struct CloudTerminalAttachmentLog: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudTerminalAttachment")

    /// Correlates resolver, attachment, and presentation observations for one
    /// attachment transaction without carrying terminal contents or payloads.
    let correlationID: String

    init(correlationID: String = UUID().uuidString.lowercased()) {
        self.correlationID = correlationID
    }

    func resolution(machineID: String, terminalID: String, attempt: Int, outcome: CloudTuiSurfaceIDResolution) {
        switch outcome {
        case let .resolved(surfaceID):
            Self.logger.info("correlation=\(correlationID, privacy: .public) resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=resolved surface=\(surfaceID)")
        case .noPlacement:
            Self.logger.info("correlation=\(correlationID, privacy: .public) resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=needs-projection")
        case .exited:
            Self.logger.notice("correlation=\(correlationID, privacy: .public) resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=exited")
        case let .retryable(reason, _):
            Self.logger.error("correlation=\(correlationID, privacy: .public) resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=retryable reason=\(reason, privacy: .private)")
        }
    }

    func daemonAnswer(machineID: String, terminalID: String, command: String, answer: CloudTuiDaemonAnswer) {
        switch answer {
        case let .rejected(code):
            Self.logger.info("correlation=\(correlationID, privacy: .public) daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) outcome=rejected rejected=\(code, privacy: .private)")
        case let .transportFailure(text):
            Self.logger.error("correlation=\(correlationID, privacy: .public) daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) outcome=transport-failure transport-failure=\(text, privacy: .private)")
        case let .unrecognized(text):
            Self.logger.error("correlation=\(correlationID, privacy: .public) daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) outcome=unrecognized unrecognized=\(text, privacy: .private)")
        }
    }

    func projection(machineID: String, terminalID: String, placement: SurfaceRemotePlacement) {
        Self.logger.info("correlation=\(correlationID, privacy: .public) project machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) outcome=projected workspace=\(placement.workspaceID, privacy: .public) tab=\(placement.tabID, privacy: .public)")
    }

    func phase(machineID: String, terminalID: String, surfaceID: UInt64, phase: CloudTuiManualMirrorPhase, reason: CloudTerminalAttachmentInterruption?) {
        let outcome: String
        switch phase {
        case .idle: outcome = "idle"
        case .connecting: outcome = "connecting"
        case .attached: outcome = "attached"
        case .disconnected: outcome = reason?.logDescription ?? "disconnected"
        case .stopped: outcome = "ended"
        }
        Self.logger.info("correlation=\(correlationID, privacy: .public) phase machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) surface=\(surfaceID) phase=\(String(describing: phase), privacy: .public) outcome=\(outcome, privacy: .public) reason=\(reason?.logDescription ?? "-", privacy: .public) detail=\(reason?.detail ?? "-", privacy: .private)")
    }

    func retry(machineID: String, failures: Int, delay: Duration) {
        Self.logger.notice("correlation=\(correlationID, privacy: .public) retry machine=\(machineID, privacy: .public) failures=\(failures) outcome=scheduled delay=\(String(describing: delay), privacy: .public)")
    }

    func giveUp(machineID: String, terminalID: String, attempts: Int, reason: String) {
        Self.logger.error("correlation=\(correlationID, privacy: .public) give-up machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempts=\(attempts) outcome=give-up reason=\(reason, privacy: .private)")
    }

    /// Records one startup milestone with a monotonic elapsed sample.
    func startupStage(
        machineID: String,
        terminalID: String,
        stage: String,
        elapsedMilliseconds: Int
    ) {
        Self.logger.info(
            "correlation=\(correlationID, privacy: .public) startup machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) stage=\(stage, privacy: .public) elapsed_ms=\(elapsedMilliseconds)"
        )
    }

    /// Records which owner presented the connection state for one pane.
    ///
    /// Only stable identities and state labels are emitted. The rendered
    /// terminal contents and any command or error payload remain absent.
    func presentation(
        machineID: String,
        terminalID: String,
        destination: String,
        visible: Bool,
        presented: Bool,
        phase: CloudTuiManualMirrorPhase,
        hasPresentation: Bool
    ) {
        Self.logger.info("correlation=\(correlationID, privacy: .public) presentation machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) destination=\(destination, privacy: .public) visible=\(visible) bound=\(presented) phase=\(String(describing: phase), privacy: .public) outcome=\(hasPresentation ? "shown" : "hidden", privacy: .public)")
    }
}

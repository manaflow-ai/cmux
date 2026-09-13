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

    func resolution(machineID: String, terminalID: String, attempt: Int, outcome: CloudTuiSurfaceIDResolution) {
        switch outcome {
        case let .resolved(surfaceID):
            Self.logger.info("resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=resolved surface=\(surfaceID)")
        case .noPlacement:
            Self.logger.info("resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=needs-projection")
        case .exited:
            Self.logger.notice("resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=exited")
        case let .retryable(reason, _):
            Self.logger.error("resolve machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempt=\(attempt) outcome=retryable reason=\(reason, privacy: .private)")
        }
    }

    func daemonAnswer(machineID: String, terminalID: String, command: String, answer: CloudTuiDaemonAnswer) {
        switch answer {
        case let .rejected(code):
            Self.logger.info("daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) rejected=\(code, privacy: .private)")
        case let .transportFailure(text):
            Self.logger.error("daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) transport-failure=\(text, privacy: .private)")
        case let .unrecognized(text):
            Self.logger.error("daemon machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) command=\(command, privacy: .public) unrecognized=\(text, privacy: .private)")
        }
    }

    func projection(machineID: String, terminalID: String, placement: SurfaceRemotePlacement) {
        Self.logger.info("project machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) workspace=\(placement.workspaceID, privacy: .public) tab=\(placement.tabID, privacy: .public)")
    }

    func phase(machineID: String, terminalID: String, surfaceID: UInt64, phase: CloudTuiManualMirrorPhase, reason: CloudTerminalAttachmentInterruption?) {
        Self.logger.info("phase machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) surface=\(surfaceID) phase=\(String(describing: phase), privacy: .public) reason=\(reason?.logDescription ?? "-", privacy: .public) detail=\(reason?.detail ?? "-", privacy: .private)")
    }

    func retry(machineID: String, failures: Int, delay: Duration) {
        Self.logger.notice("retry machine=\(machineID, privacy: .public) failures=\(failures) delay=\(String(describing: delay), privacy: .public)")
    }

    func giveUp(machineID: String, terminalID: String, attempts: Int, reason: String) {
        Self.logger.error("give-up machine=\(machineID, privacy: .public) terminal=\(terminalID, privacy: .public) attempts=\(attempts) reason=\(reason, privacy: .private)")
    }
}

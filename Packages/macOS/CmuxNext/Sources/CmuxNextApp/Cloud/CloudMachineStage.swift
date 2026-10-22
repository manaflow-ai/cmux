import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Where a Cloud machine is on its way to an open terminal (cx-lu8f). Every
/// stage comes from a real event, never from elapsed time:
/// - `requesting`: the click; the app gets the sign-in token and team;
/// - `creating`: `POST /api/vm` is on the wire (the server creates the VM);
/// - `booting`: the VM exists; its link (attach endpoint, tunnel, `cmux-tui
///   remote connect`) waits for the machine's cmux-tui to answer;
/// - `connecting`: the link is up; the daemon handshake and first snapshot;
/// - `ready`: the machine's daemon tree is loaded (the terminal opens);
/// - `paused`: the machine is paused (by the idle auto-pause or a person's
///   Pause Machine) and nothing attached yet; not a failure, and an attach
///   resumes it;
/// - `failed`: why it stopped, from the API, the link or the daemon.
nonisolated enum CloudMachineStage: Hashable, Sendable {
    case requesting
    case creating
    case booting
    case connecting
    case ready
    /// Paused; `idle` when the idle auto-pause paused it.
    case paused(idle: Bool)
    case failed(String)

    /// The stages in order, for the progress list (no `paused` or `failed`).
    static let steps: [CloudMachineStage] = [.requesting, .creating, .booting, .connecting, .ready]

    /// The position in `steps`; a failure has none.
    var stepIndex: Int? { Self.steps.firstIndex(of: self) }

    /// Machine-readable name (`cloud.machines` `stage`).
    var name: String {
        switch self {
        case .requesting: "requesting"
        case .creating: "creating"
        case .booting: "booting"
        case .connecting: "connecting"
        case .ready: "ready"
        case .paused: "paused"
        case .failed: "failed"
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var failure: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    var isFinished: Bool { self == .ready || isPaused || failure != nil }
}

/// What the stage is derived from: plain values, so the rule is testable
/// without a network, a link or a daemon.
nonisolated struct CloudMachineStageInput: Hashable, Sendable {
    var creation: CloudCreationPhase?
    var machineStatus: CloudMachine.Status?
    var link: CloudLinkPhase = .idle
    var daemonConnected = false
    var daemonLoaded = false
    /// The daemon's first connect gave up (`DaemonService.startup`), with
    /// the last failure the store showed; nil while it still tries.
    var daemonFailure: String?
    /// The app link ended ("click to connect"), nil otherwise.
    var linkEnded: String?
    /// Why a paused machine is paused (`/api/vm` `pauseReason`).
    var pauseReason: CloudMachine.PauseReason?
    /// An attach is resuming the paused machine.
    var resuming = false
    /// Why the attach's resume failed, nil otherwise.
    var resumeFailure: String?

    /// The stage. A link that is still starting is `booting` even after the
    /// daemon's ten-second first-connect deadline: a new VM's link takes
    /// that long by itself, so only a link that failed, or a daemon that
    /// failed behind a live link, is a failure.
    var stage: CloudMachineStage {
        switch creation {
        case .requesting: return .requesting
        case .creating: return .creating
        case .failed(let reason): return .failed(reason)
        case .created, nil: break
        }
        if daemonConnected, daemonLoaded { return .ready }
        if machineStatus == .paused {
            // A paused machine is not a failure: it reads "Paused (idle)" or
            // "Paused" until an attach resumes it. An app link ends when its
            // machine pauses, so an ended link on a paused machine is the
            // pause, not a failure.
            if resuming { return .booting }
            if let resumeFailure { return .failed(resumeFailure) }
            if link == .idle || linkEnded != nil { return .paused(idle: pauseReason == .idle) }
        }
        if let linkEnded { return .failed(linkEnded) }
        if machineStatus == .failed { return .failed(CloudStrings.machineFailed) }
        switch link {
        case .up:
            if let daemonFailure { return .failed(daemonFailure) }
            return .connecting
        case .failed(let reason):
            return daemonFailure == nil ? .booting : .failed(reason)
        case .idle, .starting:
            return .booting
        }
    }
}

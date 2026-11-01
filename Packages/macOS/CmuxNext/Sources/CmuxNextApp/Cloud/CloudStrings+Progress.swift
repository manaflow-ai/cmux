import CmuxNextCloud
import Foundation

/// The New Cloud Workspace progress text (cx-lu8f). Keys live in
/// Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    nonisolated private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Cloud", bundle: .module)
    }

    /// One stage's name in the progress list, the sidebar row and the
    /// accessibility label.
    static func stage(_ stage: CloudMachineStage) -> String {
        switch stage {
        case .requesting: text("cloud.progress.stage.requesting", "Requesting a machine")
        case .creating: text("cloud.progress.stage.creating", "Creating the VM")
        case .booting: text("cloud.progress.stage.booting", "Starting the machine")
        case .connecting: text("cloud.progress.stage.connecting", "Connecting to cmux-tui")
        case .ready: text("cloud.progress.stage.ready", "Ready")
        case .paused(idle: true): text("cloud.progress.stage.pausedIdle", "Paused (idle)")
        case .paused(idle: false): text("cloud.progress.stage.paused", "Paused")
        case .pausing: text("cloud.progress.stage.pausing", "Pausing…")
        case .resuming: text("cloud.progress.stage.resuming", "Resuming…")
        case .deleting: text("cloud.progress.stage.deleting", "Deleting…")
        case .failed: text("cloud.progress.stage.failed", "Failed")
        }
    }

    /// What happens next, under the steps.
    static func stageNext(_ stage: CloudMachineStage) -> String {
        switch stage {
        case .requesting: text("cloud.progress.next.requesting", "Sending the request to cmux Cloud.")
        case .creating: text("cloud.progress.next.creating", "cmux Cloud is creating the VM. A new machine usually takes under a minute.")
        case .booting: text("cloud.progress.next.booting", "The VM exists. This Mac is opening a link to it and waits for its cmux-tui to answer.")
        case .connecting: text("cloud.progress.next.connecting", "The link is up. Loading the machine's workspaces.")
        case .paused(idle: true): text("cloud.progress.next.pausedIdle", "cmux Cloud paused this machine after it sat idle. Its disk and session are kept. Resume starts it again.")
        case .paused(idle: false): text("cloud.progress.next.paused", "This machine is paused. Its disk and session are kept. Resume starts it again.")
        case .pausing: text("cloud.progress.next.pausing", "cmux Cloud is pausing this machine. Its disk and session are kept. Resume works once it is paused.")
        case .resuming: text("cloud.progress.next.resuming", "cmux Cloud is starting this machine again. It connects once it runs.")
        case .deleting: text("cloud.progress.next.deleting", "cmux Cloud is deleting this machine and its disk.")
        case .ready, .failed: text("cloud.progress.next.ready", "Opening the terminal.")
        }
    }

    /// A machine header's tooltip line when the server's last pause, resume or resize of it failed.
    static func changeFailed(_ reason: String) -> String {
        String(format: text("cloud.machine.changeFailed", "The last change to this machine failed: %@"), reason)
    }

    /// Why Pause, Resume or Kill waits on a machine in `status` (``CloudMachineStage/gatePowerActions(into:context:)``).
    static func machineChanging(_ status: CloudMachine.Status) -> String? {
        switch status {
        case .pausing: text("cloud.machine.busy.pausing", "This machine is pausing. Try again once it is paused.")
        case .starting: text("cloud.machine.busy.resuming", "This machine is resuming. Try again once it is running.")
        case .deleting: text("cloud.machine.busy.deleting", "This machine is being deleted.")
        default: nil
        }
    }

    static var newCloudWorkspaceTitle: String { text("cloud.progress.title.new", "New Cloud Workspace") }

    static func progressTitle(machine: String) -> String {
        String(format: text("cloud.progress.title.machine", "New Cloud Workspace on %@"), machine)
    }

    static func progressFailed(_ reason: String) -> String {
        String(format: text("cloud.progress.failed", "The Cloud machine did not start. Click Retry; Copy Error copies the details. Reason: %@"), reason)
    }

    static func elapsed(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        let clock = seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : String(format: "0:%02d", seconds)
        return String(format: text("cloud.progress.elapsed", "%@ elapsed"), clock)
    }

    static var progressTypingNote: String {
        text("cloud.progress.typing", "The terminal opens here by itself when the machine is ready. Typing starts there.")
    }

    static var retry: String { text("cloud.button.retry", "Retry") }
    static var resume: String { text("cloud.button.resume", "Resume") }
    static var copyError: String { text("cloud.button.copyError", "Copy Error") }
    static var dismiss: String { text("cloud.button.dismiss", "Dismiss") }

    /// The sidebar section of a machine whose create request has not returned.
    static var newMachine: String { text("cloud.progress.newMachine", "New Cloud machine") }

    /// The provider reported the machine failed.
    nonisolated static var machineFailed: String { text("cloud.progress.machineFailed", "cmux Cloud reports that the machine failed.") }

    // How a started bootstrap ended (`CloudMachineBootstrap.Completion`), for the wizard and the creation view.

    static func bootstrapNeedsGitHub(_ repo: String) -> String {
        String(format: String(localized: "cloud.bootstrap.needsGitHub",
                              defaultValue: "This machine has no GitHub access to %@, so it couldn't clone it.",
                              table: "Cloud", bundle: .module), repo)
    }

    static func bootstrapRepoFailed(_ repo: String, log: String) -> String {
        String(format: String(localized: "cloud.bootstrap.repoFailed",
                              defaultValue: "Couldn't clone or update %1$@ on the machine. See the log at %2$@.",
                              table: "Cloud", bundle: .module), repo, log)
    }

    static func bootstrapScriptFailed(_ code: Int, log: String) -> String {
        String(format: String(localized: "cloud.bootstrap.scriptFailed",
                              defaultValue: "The setup script failed with exit code %1$ld. See the log at %2$@.",
                              table: "Cloud", bundle: .module), code, log)
    }

    static var bootstrapRunnerNeverCame: String {
        String(localized: "cloud.bootstrap.runnerNeverCame", defaultValue: "The setup never started on the machine. Try again.",
               table: "Cloud", bundle: .module)
    }

    static func bootstrapStopped(log: String) -> String {
        String(format: String(localized: "cloud.bootstrap.stopped",
                              defaultValue: "The setup stopped on the machine before it finished. See the log at %@.",
                              table: "Cloud", bundle: .module), log)
    }

    static func bootstrapStillRunning(log: String) -> String {
        String(format: String(localized: "cloud.bootstrap.stillRunning",
                              defaultValue: "The setup is still running on the machine; see the log at %@.",
                              table: "Cloud", bundle: .module), log)
    }

    static func bootstrapUnreachable(_ error: String) -> String {
        String(format: String(localized: "cloud.bootstrap.unreachable",
                              defaultValue: "Couldn't read the setup's progress from the machine: %@",
                              table: "Cloud", bundle: .module), error)
    }

    static func bootstrapStartFailed(_ reason: String) -> String {
        String(format: String(localized: "cloud.bootstrap.startFailed", defaultValue: "The setup couldn't start on the machine: %@",
                              table: "Cloud", bundle: .module), reason)
    }
}

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
        case .ready, .failed: text("cloud.progress.next.ready", "Opening the terminal.")
        }
    }

    static var newCloudWorkspaceTitle: String { text("cloud.progress.title.new", "New Cloud Workspace") }

    static func progressTitle(machine: String) -> String {
        String(format: text("cloud.progress.title.machine", "New Cloud Workspace on %@"), machine)
    }

    static func progressFailed(_ reason: String) -> String {
        String(format: text("cloud.progress.failed", "The Cloud machine did not start: %@"), reason)
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
    static var copyError: String { text("cloud.button.copyError", "Copy Error") }
    static var dismiss: String { text("cloud.button.dismiss", "Dismiss") }

    /// The sidebar section of a machine whose create request has not returned.
    static var newMachine: String { text("cloud.progress.newMachine", "New Cloud machine") }

    /// The provider reported the machine failed.
    nonisolated static var machineFailed: String { text("cloud.progress.machineFailed", "cmux Cloud reports that the machine failed.") }

    /// A paused machine has no link until it is resumed.
    nonisolated static var machinePaused: String { text("cloud.progress.machinePaused", "The machine is paused. Resume it from its menu in the sidebar, then click Retry.") }
}

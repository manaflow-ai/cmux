import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation

/// Update Machine (cx-rppd.13): a Cloud machine whose image baked an older cmux-tui lacks verbs
/// Move to Cloud and Bring Back Local need, and their CLIs name it `machine_outdated`. That stop's
/// toast offers "Update Machine": that button runs the move again with ``argument`` set, from
/// the person (``requested(_:)``), and the run first updates the machine's cmux-tui in place to this
/// app's own pinned build (`cmux link machine update`, cmux-tui `link/machine_update.rs`), then moves
/// the chat. A move the person started in this app does the same by itself when it finds the machine
/// too old (``CloudMove/updatingFirst(_:_:)``), so it reaches the button only when the update fails.
/// Neither the CLI nor an agent can ask for it, and nothing the invocation carries reaches
/// the machine: the CLI takes only the machine daemon's socket.
///
/// The app may also start the same update by itself (``CloudMachineUpdates``): a connected
/// machine on another build than the app's is updated, also while an agent works there, with the same
/// `cmux link machine update` and the same build source (the app's own pinned build; nothing picks
/// it). That trigger lives only in the app; no CLI verb, action argument or agent reaches it. This
/// button never reads its ledger: a click always runs.
@MainActor
enum CloudMachineUpdate {
    /// The invocation argument the "Update Machine" button sets.
    static let argument = "updateMachine"

    /// Whether `invocation` is the person's "Update Machine".
    static func requested(_ invocation: ActionInvocation) -> Bool {
        invocation.origin == .user && invocation[argument] == .bool(true)
    }

    /// Updates `machine` (named `name`, its daemon at `socket`), behind toast `toastID` (none when nil:
    /// the chat's card says the move). Throws a stop whose Retry is `retry` when trying again can help.
    static func run(_ services: AppServices, name: String, socket: String, cli: CloudMoveCLI, toast toastID: String?,
                    retry: CloudMoveRetries.Retry) async throws {
        if let toastID { CloudMove.toast(services, toastID, CloudMachineUpdateStrings.updating(name), duration: CloudMoveCLI.machineUpdateTimeout, working: true) }
        let answer: CloudMoveCLI.Answer
        do {
            answer = try await cli.machineUpdate(socket: socket)
        } catch {
            throw CloudMove.Failure(message: CloudMachineUpdateStrings.failed(name, CloudStrings.errorText(error)), retry: retry)
        }
        guard !answer.ok else { return }
        services.cloud.logger.error("cloud machine update: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)")
        switch answer.errorCode {
        case "machine_update_unsupported": throw CloudMove.Failure(message: CloudMachineUpdateStrings.unsupported(name))
        case "machine_update_unavailable": throw CloudMove.Failure(message: CloudMachineUpdateStrings.unavailable(name))
        default: throw CloudMove.Failure(message: CloudMachineUpdateStrings.failed(name, answer.error ?? answer.errorCode ?? ""), retry: retry)
        }
    }
}

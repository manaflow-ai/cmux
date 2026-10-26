import CmuxNextActions
import CmuxNextCloud
import Foundation

/// Update Machine (cx-rppd.13): a Cloud machine whose image baked an older cmux-tui lacks verbs
/// Move to Cloud and Bring Back Local need, and their CLIs name it `machine_outdated`. That stop's
/// toast offers "Update Machine": only that button runs the move again with ``argument`` set, from
/// the person (``requested(_:)``), and the run first updates the machine's cmux-tui in place to this
/// app's own pinned build (`cmux link machine update`, cmux-tui `link/machine_update.rs`), then moves
/// the chat. Neither the CLI nor an agent can ask for it, and nothing the invocation carries reaches
/// the machine: the CLI takes only the machine daemon's socket.
@MainActor
enum CloudMachineUpdate {
    /// The invocation argument the "Update Machine" button sets.
    static let argument = "updateMachine"

    /// Whether `invocation` is the person's "Update Machine".
    static func requested(_ invocation: ActionInvocation) -> Bool {
        invocation.origin == .user && invocation[argument] == .bool(true)
    }

    /// Updates `machine` (named `name`, its daemon at `socket`), behind toast `toastID`. Throws a stop
    /// whose Retry is `retry` when trying again can help.
    static func run(_ services: AppServices, name: String, socket: String, cli: CloudMoveCLI, toast toastID: String,
                    retry: CloudMoveRetries.Retry) async throws {
        CloudMove.toast(services, toastID, CloudMachineUpdateStrings.updating(name), duration: CloudMoveCLI.machineUpdateTimeout)
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

/// Update Machine's text (``CloudMachineUpdate``). Keys live in Resources/Cloud.xcstrings.
enum CloudMachineUpdateStrings {
    /// The button on a `machine_outdated` stop's toast.
    static var button: String {
        String(localized: "cloud.machineUpdate.button", defaultValue: "Update Machine", table: "Cloud", bundle: .module)
    }
    static func updating(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.updating", defaultValue: "Updating cmux on %@…", table: "Cloud", bundle: .module), machine)
    }
    static func unsupported(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.unsupported", defaultValue: "%@ runs a cmux too old to update in place. Use a new Cloud machine instead.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func unavailable(_ machine: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.unavailable", defaultValue: "This build of cmux can't update %@. A release build can.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func failed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.machineUpdate.failed", defaultValue: "Couldn't update cmux on %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
}

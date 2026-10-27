import CmuxNextCloud
import Foundation

extension CloudMachineBootstrap {
    /// The end of the run a start began, in words a person reads: the New Cloud Workspace wizard opens
    /// its project at `finished`'s `repoPath`, or shows `failed`'s reason. Blocks on the machine's runner
    /// (``waitForRun(on:bound:)``), never on a timer.
    func waitForCompletion(on machine: Machine) async -> Completion {
        Self.completion(await waitForRun(on: machine))
    }

    static func completion(_ run: Run) -> Completion {
        switch run {
        case let .finished(repoPath): .finished(repoPath: repoPath)
        case let .needsGitHub(repo): .failed(reason: CloudStrings.bootstrapNeedsGitHub(repo))
        case let .repoFailed(repo): .failed(reason: CloudStrings.bootstrapRepoFailed(repo, log: logPath))
        case let .scriptFailed(code): .failed(reason: CloudStrings.bootstrapScriptFailed(code, log: logPath))
        case .runnerNeverCame: .failed(reason: CloudStrings.bootstrapRunnerNeverCame)
        case .stopped: .failed(reason: CloudStrings.bootstrapStopped(log: logPath))
        case .stillRunning: .failed(reason: CloudStrings.bootstrapStillRunning(log: logPath))
        case let .unreachable(error): .failed(reason: CloudStrings.bootstrapUnreachable(error))
        }
    }
}

/// How a machine's bootstrap ended (`CloudMachineBootstrap.Completion`), for the wizard and the
/// creation view. Keys live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
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

import CmuxNextCloud
import CmuxNextCloudUI

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
        case .needsGitHub: .repositoryFailed(reason: CloudGitHubConnectorCard.failureMessage(.privateRepository))
        case .repoOffline: .repositoryFailed(reason: CloudGitHubConnectorCard.failureMessage(.offline))
        case .repoNotFound: .repositoryFailed(reason: CloudGitHubConnectorCard.failureMessage(.notFound))
        case let .repoFailed(repo): .failed(reason: CloudStrings.bootstrapRepoFailed(repo, log: logPath))
        case let .scriptFailed(code): .failed(reason: CloudStrings.bootstrapScriptFailed(code, log: logPath))
        case .runnerNeverCame: .failed(reason: CloudStrings.bootstrapRunnerNeverCame)
        case .stopped: .failed(reason: CloudStrings.bootstrapStopped(log: logPath))
        case .stillRunning: .failed(reason: CloudStrings.bootstrapStillRunning(log: logPath))
        case let .unreachable(error): .failed(reason: CloudStrings.bootstrapUnreachable(error))
        }
    }
}

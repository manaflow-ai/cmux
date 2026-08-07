@testable import CmuxSudoBroker

actor TestRunnerLauncher: SudoRunnerLaunching {
    private(set) var launchedRequestIDs: [String] = []

    func launch(requestID: String, paths: SudoBrokerPaths) async -> SudoLaunchedRunner {
        launchedRequestIDs.append(requestID)
        return SudoLaunchedRunner(
            identity: SudoProcessIdentity(
                processIdentifier: 4_242,
                startSeconds: 10,
                startMicroseconds: 20
            )
        )
    }
}


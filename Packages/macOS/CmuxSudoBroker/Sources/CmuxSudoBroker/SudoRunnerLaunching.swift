protocol SudoRunnerLaunching: Sendable {
    func launch(requestID: String) async throws -> SudoLaunchedRunner
}

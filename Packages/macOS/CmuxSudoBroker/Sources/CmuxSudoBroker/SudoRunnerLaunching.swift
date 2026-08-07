import Foundation

protocol SudoRunnerLaunching: Sendable {
    func launch(
        requestID: String,
        reviewedScript: Data
    ) async throws -> SudoLaunchedRunner
}

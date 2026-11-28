import Foundation

protocol SudoRunnerLaunching: Sendable {
    func launch(
        requestID: String,
        reviewedScript: Data,
        manifest: SudoExecutionManifest
    ) async throws -> SudoLaunchedRunner
}

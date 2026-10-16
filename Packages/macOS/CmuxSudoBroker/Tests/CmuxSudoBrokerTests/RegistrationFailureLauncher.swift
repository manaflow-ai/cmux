@testable import CmuxSudoBroker
import Foundation

actor RegistrationFailureLauncher: SudoRunnerLaunching {
    let paths: SudoBrokerPaths
    private var termination: AsyncStream<Int32>.Continuation?

    init(paths: SudoBrokerPaths) { self.paths = paths }

    func launch(
        requestID: String, reviewedScript: Data, manifest: SudoExecutionManifest
    ) async throws -> SudoLaunchedRunner {
        let lock = paths.locks.appendingPathComponent("\(requestID).lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let termination = AsyncStream<Int32>.makeStream()
        self.termination = termination.continuation
        return SudoLaunchedRunner(
            identity: TestRunnerLauncher.defaultRunnerIdentity, termination: termination.stream
        )
    }

    func allowRegistration(requestID: String) throws {
        try FileManager.default.removeItem(at: paths.locks.appendingPathComponent("\(requestID).lock"))
    }

    func finish() {
        termination?.yield(1)
        termination?.finish()
        termination = nil
    }
}

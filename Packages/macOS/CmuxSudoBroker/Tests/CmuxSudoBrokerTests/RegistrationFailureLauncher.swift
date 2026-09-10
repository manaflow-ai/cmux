@testable import CmuxSudoBroker
import Foundation

struct RegistrationFailureLauncher: SudoRunnerLaunching {
    let paths: SudoBrokerPaths

    func launch(
        requestID: String, reviewedScript: Data, manifest: SudoExecutionManifest
    ) async throws -> SudoLaunchedRunner {
        let lock = paths.locks.appendingPathComponent("\(requestID).lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let termination = AsyncStream<Int32>.makeStream()
        termination.continuation.yield(1)
        termination.continuation.finish()
        return SudoLaunchedRunner(
            identity: TestRunnerLauncher.defaultRunnerIdentity, termination: termination.stream
        )
    }
}

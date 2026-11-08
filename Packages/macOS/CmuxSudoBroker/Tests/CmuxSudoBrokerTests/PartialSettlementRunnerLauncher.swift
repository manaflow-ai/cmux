@testable import CmuxSudoBroker
import Foundation

struct PartialSettlementRunnerLauncher: SudoRunnerLaunching {
    let paths: SudoBrokerPaths

    func launch(
        requestID: String, reviewedScript: Data, manifest: SudoExecutionManifest
    ) async throws -> SudoLaunchedRunner {
        let store = SudoSpoolStore(paths: paths, fileManager: FailFirstArchiveMoveFileManager())
        do {
            _ = try store.settle(SudoResult(
                id: requestID, status: .failed, errorCode: .runnerLaunchFailed,
                note: SudoFailureMessages.testMessages.runnerLaunchFailed
            ))
            throw FixtureError.archiveDidNotFail
        } catch SudoSpoolError.settlementIncomplete {}
        let termination = AsyncStream<Int32>.makeStream()
        termination.continuation.yield(1)
        termination.continuation.finish()
        // Match the failure path that already joined the launcher's reaper.
        var iterator = termination.stream.makeAsyncIterator()
        _ = await iterator.next()
        return SudoLaunchedRunner(
            identity: TestRunnerLauncher.defaultRunnerIdentity, termination: termination.stream
        )
    }

    private enum FixtureError: Error { case archiveDidNotFail }
}

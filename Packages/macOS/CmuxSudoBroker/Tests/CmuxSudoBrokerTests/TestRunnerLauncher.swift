@testable import CmuxSudoBroker
import Foundation

actor TestRunnerLauncher: SudoRunnerLaunching {
    private(set) var launchedRequestIDs: [String] = []
    private(set) var reviewedScripts: [String: Data] = [:]
    private var terminationContinuations: [String: AsyncStream<Int32>.Continuation] = [:]

    func launch(requestID: String) async -> SudoLaunchedRunner {
        makeRunner(requestID: requestID)
    }

    func launch(
        requestID: String,
        reviewedScript: Data,
        manifest: SudoExecutionManifest
    ) async -> SudoLaunchedRunner {
        reviewedScripts[requestID] = reviewedScript
        return makeRunner(requestID: requestID)
    }

    private func makeRunner(requestID: String) -> SudoLaunchedRunner {
        launchedRequestIDs.append(requestID)
        let pair = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        terminationContinuations[requestID] = pair.continuation
        return SudoLaunchedRunner(termination: pair.stream)
    }

    func terminate(requestID: String) {
        guard let continuation = terminationContinuations.removeValue(forKey: requestID) else {
            return
        }
        continuation.yield(4_242)
        continuation.finish()
    }
}

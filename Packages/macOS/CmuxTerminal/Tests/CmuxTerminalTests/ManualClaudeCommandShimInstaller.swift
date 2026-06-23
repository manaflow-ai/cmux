import Foundation
import CmuxTerminalCore
@testable import CmuxTerminal

actor ManualClaudeCommandShimInstaller {
    private var installContinuations: [CheckedContinuation<TerminalSurfaceClaudeCommandShim?, Never>] = []
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var completedResult: TerminalSurfaceClaudeCommandShim?
    private var didComplete = false

    func install(
        wrapperURL: URL,
        surfaceId: UUID,
        temporaryDirectory: URL
    ) async -> TerminalSurfaceClaudeCommandShim? {
        _ = wrapperURL
        _ = surfaceId
        _ = temporaryDirectory
        if didComplete {
            return completedResult
        }
        return await withCheckedContinuation { continuation in
            installContinuations.append(continuation)
            resumeStartContinuations()
        }
    }

    func waitForInstallStart() async {
        guard installContinuations.isEmpty, !didComplete else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func complete(with result: TerminalSurfaceClaudeCommandShim? = nil) {
        didComplete = true
        completedResult = result
        let continuations = installContinuations
        installContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: result)
        }
        resumeStartContinuations()
    }

    private func resumeStartContinuations() {
        let continuations = startContinuations
        startContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

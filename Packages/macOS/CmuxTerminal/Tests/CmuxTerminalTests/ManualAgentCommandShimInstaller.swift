import Foundation
import CmuxTerminalCore
@testable import CmuxTerminal

actor ManualAgentCommandShimInstaller {
    private var installContinuations: [CheckedContinuation<TerminalSurfaceAgentCommandShimSet?, Never>] = []
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var completedResult: TerminalSurfaceAgentCommandShimSet?
    private var didComplete = false

    func install(
        wrapperDirectoryURL: URL,
        surfaceId: UUID,
        temporaryDirectory: URL
    ) async -> TerminalSurfaceAgentCommandShimSet? {
        _ = wrapperDirectoryURL
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

    func complete(with result: TerminalSurfaceAgentCommandShimSet? = nil) {
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

import Foundation

@MainActor
extension FileSearchController {
    func cancel(clear: Bool) {
        request = nil
        stopAndAdvanceGeneration()
        if clear {
            results.removeAll()
            emit(status: .idle, isSearching: false)
        }
    }

    func stopAndAdvanceGeneration() {
        generation += 1
        stopCurrentProcess()
    }

    private func stopCurrentProcess() {
        let process = self.process
        self.process = nil
        searchTask?.cancel()
        searchTask = nil
        clearPipelineForLifecycle()
        guard let process else { return }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
        }
    }

}

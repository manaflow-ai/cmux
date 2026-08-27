import Foundation

/// Completes a browser render lease only after its cancelled operation has stopped.
@MainActor
final class BrowserScreenshotRenderLease<Success> {
    private let teardown: @MainActor () -> Void
    private let completion: @MainActor (Result<Success, Error>) -> Void
    private var operationTask: Task<Void, Never>?
    private var operationWasInstalled = false
    private var terminalResult: Result<Success, Error>?

    init(
        teardown: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (Result<Success, Error>) -> Void
    ) {
        self.teardown = teardown
        self.completion = completion
    }

    /// Registers the operation whose teardown must precede host restoration.
    func installOperationTask(_ task: Task<Void, Never>) {
        guard !operationWasInstalled else {
            task.cancel()
            return
        }
        operationWasInstalled = true
        operationTask = task
        beginTeardownIfReady()
    }

    /// Accepts the first terminal result and cancels the registered operation.
    @discardableResult
    func finish(_ result: Result<Success, Error>) -> Bool {
        guard terminalResult == nil else { return false }
        terminalResult = result
        beginTeardownIfReady()
        return true
    }

    private func beginTeardownIfReady() {
        guard operationWasInstalled,
              let operationTask,
              let terminalResult else {
            return
        }
        self.operationTask = nil
        operationTask.cancel()
        let teardown = self.teardown
        let completion = self.completion

        // This terminal task has no later lifecycle transition that can cancel it.
        Task { @MainActor in
            await operationTask.value
            teardown()
            completion(terminalResult)
        }
    }
}

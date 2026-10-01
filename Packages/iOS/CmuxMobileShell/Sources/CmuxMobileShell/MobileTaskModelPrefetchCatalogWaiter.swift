internal import CmuxMobileShellModel

/// Detaches one canceled prefetch consumer from the shared catalog task.
actor MobileTaskModelPrefetchCatalogWaiter {
    private var didCancel = false
    private var didFinish = false
    private var continuation: CheckedContinuation<MobileTaskModelListResult?, Never>?
    private var task: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<MobileTaskModelListResult?, Never>,
        task: Task<[MobileTaskAgentProvider: MobileTaskModelListResult], any Error>,
        provider: MobileTaskAgentProvider
    ) {
        guard !didFinish else {
            continuation.resume(returning: nil)
            return
        }
        guard !didCancel else {
            didFinish = true
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        self.task = Task { [weak self] in
            let result = try? await task.value[provider]
            await self?.finish(result)
        }
    }

    func cancel() {
        didCancel = true
        finish(nil)
    }

    private func finish(_ result: MobileTaskModelListResult?) {
        guard !didFinish else { return }
        didFinish = true
        task?.cancel()
        task = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

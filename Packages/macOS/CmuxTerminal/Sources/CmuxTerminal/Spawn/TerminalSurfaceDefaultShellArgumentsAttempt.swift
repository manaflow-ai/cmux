actor TerminalSurfaceDefaultShellArgumentsAttempt {
    private let fallback: [String]
    private var result: [String]?
    private var continuation: CheckedContinuation<[String], Never>?
    private var argumentTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(fallback: [String]) {
        self.fallback = fallback
    }

    func start(
        task: Task<[String], Never>,
        deadline: Duration,
        clock: any Clock<Duration>
    ) {
        precondition(argumentTask == nil && deadlineTask == nil)
        guard result == nil else { return }
        argumentTask = Task.detached(priority: .utility) { [weak self] in
            let arguments = await task.value
            await self?.resolve(arguments)
        }
        deadlineTask = Task.detached(priority: .utility) { [weak self, fallback] in
            do {
                try await clock.sleep(for: deadline, tolerance: nil)
            } catch {
                return
            }
            await self?.resolve(fallback)
        }
    }

    func value() async -> [String] {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    nonisolated func cancel() {
        Task {
            await self.resolveFallback()
        }
    }

    private func resolveFallback() {
        resolve(fallback)
    }

    private func resolve(_ arguments: [String]) {
        guard result == nil else { return }
        result = arguments
        let continuation = self.continuation
        self.continuation = nil
        let argumentTask = self.argumentTask
        self.argumentTask = nil
        let deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        argumentTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(returning: arguments)
    }
}

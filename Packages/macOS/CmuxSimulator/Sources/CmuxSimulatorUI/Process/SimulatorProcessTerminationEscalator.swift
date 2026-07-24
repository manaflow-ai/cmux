import CmuxSimulator

actor SimulatorProcessTerminationEscalator {
    private let process: SimulatorProcessGroupProcess
    private var escalationTask: Task<Void, Never>?

    init(process: SimulatorProcessGroupProcess) {
        self.process = process
    }

    func escalate(
        sleeper: any SimulatorProcessSleeper,
        interruptGracePeriod: Duration,
        terminationGracePeriod: Duration
    ) async {
        await process.setTerminationHandler { [weak self] _ in
            Task { await self?.cancelEscalation() }
        }
        guard await process.isRunning else { return }
        process.interrupt()
        let process = process
        let task = Task {
            guard await process.isRunning else { return }
            do {
                try await sleeper.sleep(for: interruptGracePeriod)
            } catch {
                return
            }
            guard await process.isRunning else { return }
            process.terminate()
            do {
                try await sleeper.sleep(for: terminationGracePeriod)
            } catch {
                return
            }
            guard await process.isRunning else { return }
            process.forceKill()
        }
        escalationTask = task
        await task.value
        escalationTask = nil
    }

    private func cancelEscalation() {
        escalationTask?.cancel()
        escalationTask = nil
    }
}

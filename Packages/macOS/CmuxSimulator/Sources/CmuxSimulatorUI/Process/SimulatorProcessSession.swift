import Darwin
import Foundation
import CmuxSimulator

protocol SimulatorProcessSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSimulatorProcessSleeper: SimulatorProcessSleeper {
    private let clock = ContinuousClock()

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

@MainActor
final class SimulatorProcessSession {
    private(set) var isRunning = false
    private var process: SimulatorProcessGroupProcess?
    private let outputPipe = Pipe()
    private let sleeper: any SimulatorProcessSleeper
    private let interruptGracePeriod: Duration
    private let terminationGracePeriod: Duration
    private let terminationEvents: AsyncStream<Void>
    private let terminationContinuation: AsyncStream<Void>.Continuation
    private var outputTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?

    init(
        sleeper: any SimulatorProcessSleeper = ContinuousSimulatorProcessSleeper(),
        interruptGracePeriod: Duration = .seconds(2),
        terminationGracePeriod: Duration = .seconds(1)
    ) {
        self.sleeper = sleeper
        self.interruptGracePeriod = interruptGracePeriod
        self.terminationGracePeriod = terminationGracePeriod
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        terminationEvents = stream
        terminationContinuation = continuation
    }

    func start(
        _ descriptor: SimulatorCommandDescriptor,
        capturesOutput: Bool,
        onOutput: @escaping @MainActor (String) -> Void,
        onTermination: @escaping @MainActor () -> Void
    ) throws {
        guard !isRunning else { return }
        if capturesOutput {
            let handle = outputPipe.fileHandleForReading
            let reader = SimulatorProcessOutputReader(fileDescriptor: handle.fileDescriptor)
            outputTask = Task { @MainActor in
                for await batch in reader.batches() {
                    guard !Task.isCancelled else { return }
                    onOutput(batch.joined())
                }
            }
        }
        do {
            let outputDescriptor = capturesOutput
                ? outputPipe.fileHandleForWriting.fileDescriptor
                : nil
            let descriptorsToClose = capturesOutput
                ? [
                    outputPipe.fileHandleForReading.fileDescriptor,
                    outputPipe.fileHandleForWriting.fileDescriptor,
                ]
                : []
            let process = try SimulatorProcessGroupProcess.launch(
                executableURL: URL(fileURLWithPath: descriptor.executable),
                arguments: descriptor.arguments,
                standardOutputFD: outputDescriptor,
                standardErrorFD: outputDescriptor,
                fileDescriptorsToClose: descriptorsToClose,
                grouping: .dedicatedProcessGroup
            )
            self.process = process
            isRunning = true
            process.setTerminationHandler { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard let self, self.process === process else { return }
                    self.isRunning = false
                    self.process = nil
                    self.escalationTask?.cancel()
                    self.escalationTask = nil
                    self.terminationContinuation.yield(())
                    self.terminationContinuation.finish()
                    if let outputTask = self.outputTask {
                        await outputTask.value
                    }
                    self.outputTask = nil
                    onTermination()
                }
            }
            if capturesOutput {
                try? outputPipe.fileHandleForWriting.close()
            }
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            outputTask?.cancel()
            outputTask = nil
            terminationContinuation.finish()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        _ = startEscalationIfNeeded()
    }

    func stopAndWait() async {
        guard isRunning else { return }
        let task = startEscalationIfNeeded()
        await task.value
    }

    private func startEscalationIfNeeded() -> Task<Void, Never> {
        if let escalationTask { return escalationTask }
        guard let process else { return Task {} }
        let terminationEvents = terminationEvents
        let sleeper = sleeper
        let interruptGracePeriod = interruptGracePeriod
        let terminationGracePeriod = terminationGracePeriod
        let task = Task.detached {
            await Self.performStopAndWait(
                process: process,
                terminationEvents: terminationEvents,
                sleeper: sleeper,
                interruptGracePeriod: interruptGracePeriod,
                terminationGracePeriod: terminationGracePeriod
            )
        }
        escalationTask = task
        return task
    }

    nonisolated private static func performStopAndWait(
        process: SimulatorProcessGroupProcess,
        terminationEvents: AsyncStream<Void>,
        sleeper: any SimulatorProcessSleeper,
        interruptGracePeriod: Duration,
        terminationGracePeriod: Duration
    ) async {
        guard process.isRunning else { return }
        process.interrupt()
        if await waitForTermination(
            events: terminationEvents,
            sleeper: sleeper,
            for: interruptGracePeriod
        ) == .terminated { return }

        guard process.isRunning else { return }
        process.terminate()
        if await waitForTermination(
            events: terminationEvents,
            sleeper: sleeper,
            for: terminationGracePeriod
        ) == .terminated { return }

        guard process.isRunning else { return }
        process.forceKill()
    }

    nonisolated static func waitForTermination(
        events terminationEvents: AsyncStream<Void>,
        sleeper: any SimulatorProcessSleeper,
        for duration: Duration
    ) async -> TerminationWaitResult {
        return await withTaskGroup(of: TerminationWaitResult.self) { group in
            group.addTask {
                var iterator = terminationEvents.makeAsyncIterator()
                guard await iterator.next() != nil else { return .cancelled }
                return .terminated
            }
            group.addTask {
                do {
                    try await sleeper.sleep(for: duration)
                } catch {
                    return .cancelled
                }
                return .deadlineReached
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    deinit {
        escalationTask?.cancel()
        if let process, process.isRunning {
            SimulatorProcessTerminationHandle(process: process).escalate(
                sleeper: sleeper,
                interruptGracePeriod: interruptGracePeriod,
                terminationGracePeriod: terminationGracePeriod
            )
        }
        outputTask?.cancel()
        terminationContinuation.finish()
    }
}

private final class SimulatorProcessTerminationHandle: @unchecked Sendable {
    /// A synchronous lock is required because process termination callbacks
    /// race task installation without an async callback surface.
    private let lock = NSLock()
    private let process: SimulatorProcessGroupProcess
    private var escalationTask: Task<Void, Never>?

    init(process: SimulatorProcessGroupProcess) {
        self.process = process
    }

    func escalate(
        sleeper: any SimulatorProcessSleeper,
        interruptGracePeriod: Duration,
        terminationGracePeriod: Duration
    ) {
        process.setTerminationHandler { [weak self] _ in
            self?.cancelEscalation()
        }
        guard process.isRunning else { return }
        process.interrupt()
        let task = Task.detached { [self] in
            guard process.isRunning else { return }
            do {
                // This bounded grace is the intended SIGINT-to-SIGTERM deadline.
                try await sleeper.sleep(for: interruptGracePeriod)
            } catch {
                return
            }
            guard process.isRunning else { return }
            process.terminate()
            do {
                // This bounded grace is the intended SIGTERM-to-SIGKILL deadline.
                try await sleeper.sleep(for: terminationGracePeriod)
            } catch {
                return
            }
            guard process.isRunning else { return }
            process.forceKill()
        }
        let keepTask = lock.withLock { () -> Bool in
            guard process.isRunning else { return false }
            escalationTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    private func cancelEscalation() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = escalationTask
            escalationTask = nil
            return task
        }
        task?.cancel()
    }
}

enum TerminationWaitResult: Equatable, Sendable {
    case terminated
    case deadlineReached
    case cancelled
}

import Darwin
import Foundation
import CmuxSimulator

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
    private var outputReader: SimulatorProcessOutputReader?
    private var escalationTask: Task<Void, Never>?
    private var onTermination: (@MainActor @Sendable () -> Void)?

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
        onOutput: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @MainActor @Sendable () -> Void
    ) throws {
        guard !isRunning else { return }
        if capturesOutput {
            let handle = outputPipe.fileHandleForReading
            let reader = SimulatorProcessOutputReader(fileDescriptor: handle.fileDescriptor)
            outputReader = reader
            outputTask = Task.detached {
                for await batch in reader.batches() {
                    guard !Task.isCancelled else { return }
                    await onOutput(batch.joined())
                }
            }
        }
        do {
            let outputDescriptor = capturesOutput
                ? outputPipe.fileHandleForWriting.fileDescriptor
                : nil
            var descriptorsToClose: [Int32] = []
            if capturesOutput {
                descriptorsToClose += [
                    outputPipe.fileHandleForReading.fileDescriptor,
                    outputPipe.fileHandleForWriting.fileDescriptor,
                ]
            }
            let process = try SimulatorProcessGroupProcess(
                executableURL: URL(fileURLWithPath: descriptor.executable),
                arguments: descriptor.arguments,
                standardOutputFD: outputDescriptor,
                standardErrorFD: outputDescriptor,
                fileDescriptorsToClose: descriptorsToClose
            )
            self.process = process
            self.onTermination = onTermination
            isRunning = true
            Task { [weak self, weak process] in
                await process?.setTerminationHandler { [weak self, weak process] _ in
                    Task { @MainActor [weak self, weak process] in
                        guard let self, self.process === process else { return }
                        self.process = nil
                        if let outputTask = self.outputTask {
                            await outputTask.value
                        }
                        self.outputTask = nil
                        self.outputReader = nil
                        self.finishTermination()
                    }
                }
            }
            if capturesOutput {
                try? outputPipe.fileHandleForWriting.close()
            }
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            outputTask?.cancel()
            outputTask = nil
            outputReader?.cancel()
            outputReader = nil
            self.onTermination = nil
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
        let result = await waitForSimulatorProcessTermination(
            events: terminationEvents,
            sleeper: ContinuousSimulatorProcessSleeper(),
            for: .seconds(2)
        )
        if result != .terminated, isRunning {
            outputReader?.cancel()
            outputTask?.cancel()
            process = nil
            outputTask = nil
            outputReader = nil
            finishTermination()
        }
    }

    private func finishTermination() {
        guard isRunning else { return }
        let callback = onTermination
        onTermination = nil
        callback?()
        isRunning = false
        terminationContinuation.yield(())
        terminationContinuation.finish()
        escalationTask = nil
    }

    private func startEscalationIfNeeded() -> Task<Void, Never> {
        if let escalationTask { return escalationTask }
        guard let process else { return Task {} }
        let terminationEvents = terminationEvents
        let sleeper = sleeper
        let interruptGracePeriod = interruptGracePeriod
        let terminationGracePeriod = terminationGracePeriod
        let task = Task.detached {
            await performSimulatorProcessStopAndWait(
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

    deinit {
        escalationTask?.cancel()
        if let process, isRunning {
            let escalator = SimulatorProcessTerminationEscalator(process: process)
            let sleeper = sleeper
            let interruptGracePeriod = interruptGracePeriod
            let terminationGracePeriod = terminationGracePeriod
            Task {
                await escalator.escalate(
                    sleeper: sleeper,
                    interruptGracePeriod: interruptGracePeriod,
                    terminationGracePeriod: terminationGracePeriod
                )
            }
        }
        outputTask?.cancel()
        outputReader?.cancel()
        terminationContinuation.finish()
    }
}

private func performSimulatorProcessStopAndWait(
    process: SimulatorProcessGroupProcess,
    terminationEvents: AsyncStream<Void>,
    sleeper: any SimulatorProcessSleeper,
    interruptGracePeriod: Duration,
    terminationGracePeriod: Duration
) async {
    guard await process.isRunning else { return }
    process.interrupt()
    if await waitForSimulatorProcessTermination(
        events: terminationEvents,
        sleeper: sleeper,
        for: interruptGracePeriod
    ) == .terminated { return }

    guard await process.isRunning else { return }
    process.terminate()
    if await waitForSimulatorProcessTermination(
        events: terminationEvents,
        sleeper: sleeper,
        for: terminationGracePeriod
    ) == .terminated { return }

    guard await process.isRunning else { return }
    process.forceKill()
    _ = await waitForSimulatorProcessTermination(
        events: terminationEvents,
        sleeper: ContinuousSimulatorProcessSleeper(),
        for: .seconds(2)
    )
}

func waitForSimulatorProcessTermination(
    events terminationEvents: AsyncStream<Void>,
    sleeper: any SimulatorProcessSleeper,
    for duration: Duration
) async -> TerminationWaitResult {
    await withTaskGroup(of: TerminationWaitResult.self) { group in
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

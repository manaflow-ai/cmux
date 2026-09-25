import Foundation

actor SimulatorBoundedCommandRunState {
    private var continuation: CheckedContinuation<SimulatorBoundedCommandResult, Never>?
    private var standardOutput: SimulatorCapturedStream?
    private var standardError: SimulatorCapturedStream?
    private var didTerminate = false
    private var exitStatus: Int32?
    private var process: SimulatorProcessGroupProcess?
    private var deadlineTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?
    private var launchInProgress = false
    private var deferredImmediateResult: SimulatorBoundedCommandResult?
    private var captureReaders: [FileHandle] = []

    init(continuation: CheckedContinuation<SimulatorBoundedCommandResult, Never>) {
        self.continuation = continuation
    }

    var isFinished: Bool {
        continuation == nil
    }

    func beginLaunch() -> Bool {
        guard continuation != nil else { return false }
        launchInProgress = true
        return true
    }

    func installCaptureReaders(_ readers: [FileHandle]) {
        captureReaders = readers
    }

    func completeAfterTerminationDeadline() {
        guard let result = deferredImmediateResult else { return }
        captureReaders.forEach { try? $0.close() }
        captureReaders.removeAll()
        completeImmediately(result)
    }

    func install(process: SimulatorProcessGroupProcess) -> Bool {
        self.process = process
        launchInProgress = false
        completeIfReady()
        return deferredImmediateResult != nil
    }

    func recordLaunchFailure(_ result: SimulatorBoundedCommandResult) {
        launchInProgress = false
        if let deferredImmediateResult {
            self.deferredImmediateResult = nil
            completeImmediately(deferredImmediateResult)
        } else {
            completeImmediately(result)
        }
    }

    func recordStandardOutput(_ output: SimulatorCapturedStream) {
        standardOutput = output
        completeIfReady()
    }

    func recordStandardError(_ error: SimulatorCapturedStream) {
        standardError = error
        completeIfReady()
    }

    func recordTermination(_ status: Int32) {
        didTerminate = true
        exitStatus = status
        forceKillTask?.cancel()
        forceKillTask = nil
        captureReaders.removeAll()
        completeIfReady()
    }

    func requestTermination(
        _ result: SimulatorBoundedCommandResult
    ) -> SimulatorProcessGroupProcess? {
        guard continuation != nil else { return process }
        if launchInProgress, process == nil {
            if deferredImmediateResult == nil { deferredImmediateResult = result }
            return nil
        }
        guard process != nil else {
            completeImmediately(result)
            return nil
        }
        if deferredImmediateResult == nil { deferredImmediateResult = result }
        deadlineTask?.cancel()
        deadlineTask = nil
        completeIfReady()
        return process
    }

    func installDeadlineTask(_ task: Task<Void, Never>) -> Bool {
        guard continuation != nil else { return false }
        deadlineTask?.cancel()
        deadlineTask = task
        return true
    }

    func installForceKillTask(
        _ task: Task<Void, Never>,
        for process: SimulatorProcessGroupProcess
    ) -> Bool {
        guard !didTerminate, self.process === process else { return false }
        forceKillTask?.cancel()
        forceKillTask = task
        return true
    }

    private func completeIfReady() {
        guard let continuation,
              !launchInProgress,
              let standardOutput,
              let standardError,
              didTerminate else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        forceKillTask?.cancel()
        forceKillTask = nil
        if let deferredImmediateResult {
            continuation.resume(returning: deferredImmediateResult)
        } else {
            continuation.resume(returning: SimulatorBoundedCommandResult(
                standardOutput: standardOutput.data,
                standardError: standardError.data,
                outputWasTruncated: standardOutput.truncated,
                errorWasTruncated: standardError.truncated,
                exitStatus: exitStatus,
                timedOut: false,
                executionError: nil
            ))
        }
    }

    private func completeImmediately(_ result: SimulatorBoundedCommandResult) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        captureReaders.forEach { try? $0.close() }
        captureReaders.removeAll()
        continuation.resume(returning: result)
    }
}

import Darwin
import Foundation

private func withAgentForkPOSIXCStringArray<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

private func agentForkProbeProcessExitCode(processIdentifier: pid_t) -> Int32? {
    var status: Int32 = 0
    while true {
        let result = waitpid(processIdentifier, &status, 0)
        if result == processIdentifier { break }
        if result == -1 && errno == EINTR { continue }
        if result == -1 && errno == ECHILD { return 0 }
        return nil
    }
    if status & 0x7f == 0 {
        return (status >> 8) & 0xff
    }
    return 128 + (status & 0x7f)
}

actor AgentForkCommandOutputRunner {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: String?
    private var processIdentifier: pid_t?
    private var probeRootProcessIdentifier: pid_t?
    private var probeRootStartMicroseconds: Int64?
    private var verifiedProbePipeHolderStartMicroseconds: [pid_t: Int64] = [:]
    private var outputPipeHandles: Set<UInt64> = []
    private var processExitSource: DispatchSourceProcess?
    private var outputDrain: AgentForkCommandOutputDrain?
    private var outputDrainTask: Task<Data, Never>?
    private var timeoutTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<String?, Never>?
    private var completed = false
    private var waitingForOutputDrain = false
    private var timedOut = false
    private var didLaunch = false
    private var terminationRequested = false

    init(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    func start() async -> String? {
        await withCheckedContinuation { continuation in
            start(continuation: continuation)
        }
    }

    func start(continuation: CheckedContinuation<String?, Never>) {
        if completed || timedOut {
            completed = true
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation

        startTimeoutTimer()

        guard let spawned = spawnProcessGroup() else {
            markFailedBeforeLaunch()
            return
        }

        if completed {
            return
        }
        processIdentifier = spawned.processIdentifier
        probeRootProcessIdentifier = spawned.processIdentifier
        probeRootStartMicroseconds = AgentForkSupport.processStartMicroseconds(
            processIdentifier: spawned.processIdentifier
        )
        outputPipeHandles = spawned.outputPipeHandles
        guard let drain = AgentForkCommandOutputDrain(
            readFileDescriptor: spawned.readFileDescriptor,
            maximumBytes: AgentForkSupport.commandOutputMaximumBytes
        ) else {
            close(spawned.readFileDescriptor)
            signalProcessGroup(SIGKILL)
            _ = agentForkProbeProcessExitCode(processIdentifier: spawned.processIdentifier)
            processIdentifier = nil
            markFailedBeforeLaunch()
            return
        }
        outputDrain = drain
        outputDrainTask = Task.detached(priority: .utility) {
            await drain.run()
        }
        let processExitSource = DispatchSource.makeProcessSource(
            identifier: spawned.processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        processExitSource.setEventHandler { [weak self] in
            Task {
                await self?.processDidExit()
            }
        }
        self.processExitSource = processExitSource
        processExitSource.resume()
        guard Darwin.kill(spawned.processIdentifier, SIGCONT) == 0 else {
            signalProcessGroup(SIGKILL)
            _ = agentForkProbeProcessExitCode(processIdentifier: spawned.processIdentifier)
            processIdentifier = nil
            processExitSource.cancel()
            self.processExitSource = nil
            markFailedBeforeLaunch()
            return
        }
        didLaunch = true

        if terminationRequested {
            signalProcessGroup(SIGTERM)
            startKillTimer(processIdentifier: spawned.processIdentifier)
        }
    }

    private func spawnProcessGroup() -> (
        processIdentifier: pid_t,
        readFileDescriptor: Int32,
        outputPipeHandles: Set<UInt64>
    )? {
        var outputFDs: [Int32] = [-1, -1]
        defer {
            for fileDescriptor in outputFDs where fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        guard Darwin.pipe(&outputFDs) == 0 else { return nil }
        guard outputFDs.allSatisfy({ $0 > 2 }) else { return nil }
        for fileDescriptor in outputFDs {
            guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                return nil
            }
        }
        let outputPipeHandles = AgentForkSupport.probeOutputPipeHandles(
            readFileDescriptor: outputFDs[0],
            writeFileDescriptor: outputFDs[1]
        )
        guard !outputPipeHandles.isEmpty else { return nil }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var setupOK = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0) == 0
        }
        if let workingDirectoryURL = AgentForkSupport.localDirectoryURL(path: workingDirectory) {
            setupOK = setupOK && workingDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0) == 0
            }
        }
        setupOK = setupOK && posix_spawn_file_actions_adddup2(
            &fileActions,
            outputFDs[1],
            STDOUT_FILENO
        ) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(
            &fileActions,
            outputFDs[1],
            STDERR_FILENO
        ) == 0
        for fileDescriptor in outputFDs {
            setupOK = setupOK && posix_spawn_file_actions_addclose(&fileActions, fileDescriptor) == 0
        }
        guard setupOK else { return nil }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // Probes run suspended in a child-led process group. The parent
        // attaches the exit watcher before SIGCONT, so fast `--version`
        // commands cannot exit before cleanup owns their pgid.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let argv = ["/usr/bin/env", executable] + arguments
        let envp = AgentForkSupport.processEnvironmentForOpenCodeProbe(environment: environment)
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnStatus = withAgentForkPOSIXCStringArray(argv) { argvPointer in
            withAgentForkPOSIXCStringArray(envp) { envpPointer in
                "/usr/bin/env".withCString { path in
                    posix_spawn(
                        &processIdentifier,
                        path,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        envpPointer
                    )
                }
            }
        }
        guard spawnStatus == 0 else { return nil }

        close(outputFDs[1])
        outputFDs[1] = -1
        let readFD = outputFDs[0]
        outputFDs[0] = -1
        return (processIdentifier, readFD, outputPipeHandles)
    }

    private func processDidExit() {
        guard let processIdentifier else { return }
        // The process source fires before `waitpid` reaps the group leader.
        // Signal the whole group while that zombie still pins the pgid, so
        // descendants cannot leak and the pgid cannot be reused first.
        signalProcessGroup(SIGTERM)
        signalProcessGroup(SIGKILL)
        let exitStatus = agentForkProbeProcessExitCode(processIdentifier: processIdentifier)
        self.processIdentifier = nil
        processExitSource?.cancel()
        processExitSource = nil
        finish(exitStatus: exitStatus)
    }

    nonisolated func cancel() {
        Task {
            await markTimedOutAndTerminate()
        }
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .nanoseconds(Int(AgentForkSupport.commandOutputTimeoutNanoseconds)))
        timer.setEventHandler { [weak self] in
            self?.cancel()
        }
        if completed {
            timer.resume()
            timer.cancel()
            return
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func markFailedBeforeLaunch() {
        timedOut = true
        finish()
    }

    private func markTimedOutAndTerminate() {
        guard !completed else { return }
        timedOut = true
        terminationRequested = true
        terminateProcessesHoldingOutputPipe(signal: SIGTERM)
        if waitingForOutputDrain {
            terminateProcessesHoldingOutputPipe(signal: SIGKILL)
            complete(returning: nil)
            return
        }
        guard didLaunch, let processIdentifier else { return }
        signalProcessGroup(SIGTERM)
        startKillTimer(processIdentifier: processIdentifier)
    }

    private func startKillTimer(processIdentifier: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .nanoseconds(Int(AgentForkSupport.commandTerminateTimeoutNanoseconds)))
        timer.setEventHandler { [weak self] in
            Task {
                await self?.killProcessIfStillRunning(processIdentifier: processIdentifier)
            }
        }
        if completed {
            timer.resume()
            timer.cancel()
            return
        }
        killTimer?.cancel()
        killTimer = timer
        timer.resume()
    }

    private func killProcessIfStillRunning(processIdentifier: pid_t) {
        guard !completed,
              self.processIdentifier == processIdentifier else { return }
        kill(-processIdentifier, SIGKILL)
        terminateProcessesHoldingOutputPipe(signal: SIGKILL)
        reapProcessLeaderWhenItExits(processIdentifier)
        complete(returning: nil)
    }

    private func reapProcessLeaderWhenItExits(_ processIdentifier: pid_t) {
        // Completion cancels the dispatch source and resumes the caller. Keep an
        // independent reaper so a hard-killed probe leader cannot remain a zombie.
        Task.detached(priority: .utility) {
            _ = agentForkProbeProcessExitCode(processIdentifier: processIdentifier)
        }
    }

    private func signalProcessGroup(_ signal: Int32) {
        guard let processIdentifier else { return }
        kill(-processIdentifier, signal)
    }

    private func terminateProcessesHoldingOutputPipe(signal: Int32) {
        let outputPipeHandles = self.outputPipeHandles
        guard !outputPipeHandles.isEmpty else { return }
        for holder in recordProcessesHoldingOutputPipe() {
            guard AgentForkSupport.processStillHoldsProbeOutputPipe(
                holder.processIdentifier,
                outputPipeHandles: outputPipeHandles,
                expectedStartMicroseconds: holder.startMicroseconds
            ) else {
                continue
            }
            Darwin.kill(holder.processIdentifier, signal)
        }
    }

    @discardableResult
    private func recordProcessesHoldingOutputPipe() -> [
        (processIdentifier: pid_t, startMicroseconds: Int64)
    ] {
        guard !outputPipeHandles.isEmpty,
              let probeRootProcessIdentifier,
              let probeRootStartMicroseconds else { return [] }
        let holdingProcessIdentifiers = AgentForkSupport.processIdentifiersHoldingProbeOutputPipe(
            outputPipeHandles,
            excluding: [Darwin.getpid()]
        )
        let selection = AgentForkSupport.probeRelatedPipeHolderProcessIdentifiers(
            holdingProcessIdentifiers,
            probeRootProcessIdentifier: probeRootProcessIdentifier,
            probeRootStartMicroseconds: probeRootStartMicroseconds,
            verifiedStartMicrosecondsByProcessIdentifier: verifiedProbePipeHolderStartMicroseconds
        )
        verifiedProbePipeHolderStartMicroseconds.merge(
            selection.verifiedStartMicrosecondsByProcessIdentifier,
            uniquingKeysWith: { _, verified in verified }
        )
        return selection.processIdentifiers.compactMap { processIdentifier in
            verifiedProbePipeHolderStartMicroseconds[processIdentifier].map {
                (processIdentifier: processIdentifier, startMicroseconds: $0)
            }
        }
    }

    private func finish(exitStatus: Int32? = nil) {
        let killTimer: DispatchSourceTimer?
        let timedOut: Bool

        guard !completed else { return }
        killTimer = self.killTimer
        self.killTimer = nil
        timedOut = self.timedOut

        if timedOut {
            terminateProcessesHoldingOutputPipe(signal: SIGKILL)
        }
        killTimer?.cancel()

        guard !timedOut, exitStatus == 0, let outputDrainTask else {
            complete(returning: nil)
            return
        }
        waitingForOutputDrain = true
        Task {
            let output = await outputDrainTask.value
            self.finishDrainedOutput(output)
        }
    }

    private func finishDrainedOutput(_ output: Data) {
        guard !completed else { return }
        complete(returning: String(data: output, encoding: .utf8))
    }

    private func complete(returning result: String?) {
        let continuation: CheckedContinuation<String?, Never>?
        let outputDrain: AgentForkCommandOutputDrain?
        let outputDrainTask: Task<Data, Never>?
        let processExitSource: DispatchSourceProcess?
        let timeoutTimer: DispatchSourceTimer?
        let killTimer: DispatchSourceTimer?

        guard !completed else { return }
        completed = true
        waitingForOutputDrain = false
        continuation = self.continuation
        self.continuation = nil
        outputDrain = self.outputDrain
        self.outputDrain = nil
        outputDrainTask = self.outputDrainTask
        self.outputDrainTask = nil
        processExitSource = self.processExitSource
        self.processExitSource = nil
        self.processIdentifier = nil
        self.probeRootProcessIdentifier = nil
        self.probeRootStartMicroseconds = nil
        self.outputPipeHandles.removeAll(keepingCapacity: false)
        timeoutTimer = self.timeoutTimer
        self.timeoutTimer = nil
        killTimer = self.killTimer
        self.killTimer = nil

        timeoutTimer?.cancel()
        killTimer?.cancel()
        processExitSource?.cancel()
        outputDrain?.cancel()
        outputDrainTask?.cancel()
        continuation?.resume(returning: result)
    }
}

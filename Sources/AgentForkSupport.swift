import CmuxFoundation
import Foundation
import CMUXAgentLaunch
import Darwin

/// Coordinates cancellation with `Process.run()`: Foundation raises an
/// Objective-C exception if termination APIs touch a task before launch.
/// Callers own synchronization because the same gate is mutated with adjacent
/// process cancellation state.
struct ProcessTerminationGate: Sendable {
    private var didLaunch = false
    private var didFinish = false
    private var terminationRequested = false

    mutating func requestTermination() -> Bool {
        guard !didFinish else { return false }
        terminationRequested = true
        return didLaunch
    }

    mutating func markLaunched() -> Bool {
        guard !didFinish else { return false }
        didLaunch = true
        return terminationRequested
    }

    mutating func markFinished() {
        didFinish = true
    }
}

private func withPOSIXCStringArray<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

private func probeProcessExitCode(processIdentifier: pid_t) -> Int32? {
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

enum AgentForkSupport {
    static let minimumOpenCodeForkVersion = SemanticVersion(major: 1, minor: 14, patch: 50)
    // Pi v0.60.0 and OMP v13.15.0 are the first releases containing the
    // upstream CLI `--fork <path|id>` implementation.
    static let minimumPiForkVersion = SemanticVersion(major: 0, minor: 60, patch: 0)
    static let minimumOmpForkVersion = SemanticVersion(major: 13, minor: 15, patch: 0)
    private static let commandOutputTimeoutNanoseconds: Int64 = 3_000_000_000
    private static let commandTerminateTimeoutNanoseconds: Int64 = 500_000_000
    private static let commandOutputMaximumBytes = 64 * 1024
    private static let openCodeVersionProbeCache = OpenCodeVersionProbeCache()

    private actor CommandOutputRunner {
        private let executable: String
        private let arguments: [String]
        private let environment: [String: String]?
        private let workingDirectory: String?
        private var processIdentifier: pid_t?
        private var outputPipeHandles: Set<UInt64> = []
        private var processExitSource: DispatchSourceProcess?
        private var outputReadHandle: FileHandle?
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
            outputPipeHandles = spawned.outputPipeHandles
            outputReadHandle = spawned.readHandle
            let drain = CommandOutputDrain(
                readHandle: spawned.readHandle,
                maximumBytes: AgentForkSupport.commandOutputMaximumBytes
            )
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
                _ = probeProcessExitCode(processIdentifier: spawned.processIdentifier)
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
            readHandle: FileHandle,
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
            let spawnStatus = withPOSIXCStringArray(argv) { argvPointer in
                withPOSIXCStringArray(envp) { envpPointer in
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
            let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            return (processIdentifier, readHandle, outputPipeHandles)
        }

        private func processDidExit() {
            guard let processIdentifier else { return }
            // The process source fires before `waitpid` reaps the group leader.
            // Signal the whole group while that zombie still pins the pgid, so
            // descendants cannot leak and the pgid cannot be reused first.
            signalProcessGroup(SIGTERM)
            signalProcessGroup(SIGKILL)
            let exitStatus = probeProcessExitCode(processIdentifier: processIdentifier)
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
            guard !completed else { return }
            kill(-processIdentifier, SIGKILL)
            terminateProcessesHoldingOutputPipe(signal: SIGKILL)
        }

        private func signalProcessGroup(_ signal: Int32) {
            guard let processIdentifier else { return }
            kill(-processIdentifier, signal)
        }

        private func terminateProcessesHoldingOutputPipe(signal: Int32) {
            guard !outputPipeHandles.isEmpty else { return }
            for processIdentifier in AgentForkSupport.processIdentifiersHoldingProbeOutputPipe(
                outputPipeHandles,
                excluding: [Darwin.getpid()]
            ) {
                Darwin.kill(processIdentifier, signal)
            }
        }

        private func finish(exitStatus: Int32? = nil) {
            let killTimer: DispatchSourceTimer?
            let timedOut: Bool

            guard !completed else { return }
            killTimer = self.killTimer
            self.killTimer = nil
            timedOut = self.timedOut

            killTimer?.cancel()

            guard !timedOut, exitStatus == 0, let outputDrainTask else {
                complete(returning: nil)
                return
            }
            waitingForOutputDrain = true
            Task {
                let output = await outputDrainTask.value
                await self.finishDrainedOutput(output)
            }
        }

        private func finishDrainedOutput(_ output: Data) {
            guard !completed else { return }
            complete(returning: String(data: output, encoding: .utf8))
        }

        private func complete(returning result: String?) {
            let continuation: CheckedContinuation<String?, Never>?
            let outputReadHandle: FileHandle?
            let outputDrainTask: Task<Data, Never>?
            let processExitSource: DispatchSourceProcess?
            let timeoutTimer: DispatchSourceTimer?
            let killTimer: DispatchSourceTimer?

            guard !completed else { return }
            completed = true
            waitingForOutputDrain = false
            continuation = self.continuation
            self.continuation = nil
            outputReadHandle = self.outputReadHandle
            self.outputReadHandle = nil
            outputDrainTask = self.outputDrainTask
            self.outputDrainTask = nil
            processExitSource = self.processExitSource
            self.processExitSource = nil
            self.processIdentifier = nil
            self.outputPipeHandles.removeAll(keepingCapacity: false)
            timeoutTimer = self.timeoutTimer
            self.timeoutTimer = nil
            killTimer = self.killTimer
            self.killTimer = nil

            timeoutTimer?.cancel()
            killTimer?.cancel()
            processExitSource?.cancel()
            outputDrainTask?.cancel()
            try? outputReadHandle?.close()
            continuation?.resume(returning: result)
        }
    }

    private actor CommandOutputDrain {
        private let readHandle: FileHandle
        private let maximumBytes: Int

        init(readHandle: FileHandle, maximumBytes: Int) {
            self.readHandle = readHandle
            self.maximumBytes = maximumBytes
        }

        func run() -> Data {
            var output = Data()
            do {
                while true {
                    guard let chunk = try readHandle.read(upToCount: 4096),
                          !chunk.isEmpty else {
                        break
                    }
                    let remaining = maximumBytes - output.count
                    if remaining > 0 {
                        output.append(contentsOf: chunk.prefix(remaining))
                    }
                }
            } catch {
                output.removeAll(keepingCapacity: false)
            }
            try? readHandle.close()
            return output
        }
    }

    static func supportsFork(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) async -> Bool {
        guard forkCommandIdentityParts(snapshot: snapshot) != nil else { return false }
        if isRemoteContext,
           snapshot.forkStartupInput(allowLauncherScript: false) == nil {
            return false
        }
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            if isRemoteContext {
                return false
            }
            let fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            let agentID = piFamilyProbeAgentID(snapshot)
            let probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            let acceptsBareVersionOutput = piFamilyProbeExecutableMatchesAgent(
                probe.executable,
                agentID: agentID
            )
            return await supportsLocalForkProbe(
                probe: probe,
                snapshot: snapshot,
                cacheDiscriminator: "pi-family-version:\(agentID)",
                probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: true,
                usesOpenCodeVersionProbeCache: false,
                outputSupportsFork: { output in
                    piFamilyVersionSupportsFork(
                        output,
                        agentID: agentID,
                        acceptsBareVersionOutput: acceptsBareVersionOutput
                    )
                }
            )
        }
        guard snapshot.kind == .opencode else { return true }
        if snapshot.launchCommand?.launcher == "omo" {
            return true
        }
        if isRemoteContext {
            return true
        }
        guard let probe = AgentResumeCommandBuilder.openCodeVersionProbe(
            launchCommand: snapshot.launchCommand
        ) else {
            return false
        }
        return await supportsLocalForkProbe(
            probe: probe,
            snapshot: snapshot,
            cacheDiscriminator: "opencode-version",
            outputSupportsFork: { output in
                openCodeVersionSupportsFork(output)
            }
        )
    }

    static func forkValidationIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> String? {
        guard let commandIdentity = forkCommandIdentityParts(snapshot: snapshot) else { return nil }
        var parts = ["command"] + commandIdentity
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            let fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            let agentID = piFamilyProbeAgentID(snapshot)
            let probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            parts.append(
                localForkProbeValidationIdentity(
                    probe: probe,
                    snapshot: snapshot,
                    discriminator: "pi-family-version:\(agentID)",
                    probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: true
                )
            )
        } else if snapshot.kind == .opencode {
            parts.append("opencode")
            parts.append("launcher=\(normalized(snapshot.launchCommand?.launcher) ?? "")")
            if !isRemoteContext,
               let probe = AgentResumeCommandBuilder.openCodeVersionProbe(
                launchCommand: snapshot.launchCommand
               ) {
                parts.append(
                    localForkProbeValidationIdentity(
                        probe: probe,
                        snapshot: snapshot,
                        discriminator: "opencode-version"
                    )
                )
            }
        }
        return parts.joined(separator: "\u{1f}")
    }

    private static func forkCommandIdentityParts(snapshot: SessionRestorableAgentSnapshot) -> [String]? {
        guard snapshot.kind.restoreMode == .resumeSession,
              forkCommandCanRenderWithoutFilesystem(snapshot),
              normalized(snapshot.sessionId) != nil else {
            return nil
        }

        let forkArgv = AgentForkArgv()
        let launchCommand = snapshot.launchCommand
        let launchIdentity = launchCommandIdentityParts(kind: snapshot.kind, launchCommand: launchCommand)
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            guard let argv, !argv.isEmpty else { return nil }
            return ["wrapper"] + argv.map { "argv=\($0)" } + launchIdentity
        case .passthrough:
            break
        }

        if case .custom = snapshot.kind {
            guard let registration = snapshot.registration,
                  let forkCommand = normalized(registration.forkCommand) else {
                return nil
            }
            return [
                "custom",
                "registrationID=\(registration.id)",
                "forkTemplate=\(forkCommand)",
                "defaultExecutable=\(registration.defaultExecutable)",
                "cwdPolicy=\(registration.cwd.rawValue)",
                "sessionDirectory=\(normalized(registration.sessionDirectory) ?? "")",
            ] + launchIdentity
        }

        guard let argv = forkArgv.builtInKind(
            kind: snapshot.kind.rawValue,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: snapshot.permissionMode
        ), !argv.isEmpty else {
            return nil
        }
        return ["builtIn"] + argv.map { "argv=\($0)" } + launchIdentity
    }

    private static func forkCommandCanRenderWithoutFilesystem(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard snapshot.kind.restoreMode == .resumeSession,
              normalized(snapshot.sessionId) != nil else {
            return false
        }
        let forkArgv = AgentForkArgv()
        let launchCommand = snapshot.launchCommand
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv?.isEmpty == false
        case .passthrough:
            break
        }

        if case .custom = snapshot.kind {
            guard let registration = snapshot.registration,
                  let forkCommand = normalized(registration.forkCommand) else {
                return false
            }
            return customForkTemplateCanRenderWithoutFilesystem(
                forkCommand,
                registration: registration,
                snapshot: snapshot
            )
        }

        return forkArgv.builtInKind(
            kind: snapshot.kind.rawValue,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: snapshot.permissionMode
        )?.isEmpty == false
    }

    private static func customForkTemplateCanRenderWithoutFilesystem(
        _ template: String,
        registration: CmuxVaultAgentRegistration,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        if template.contains("{{cwd}}"),
           normalized(snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory) == nil {
            return false
        }
        if template.contains("{{sessionDir}}"),
           normalized(registration.sessionDirectory) == nil {
            return false
        }
        if template.contains("{{executable}}") {
            let arguments = snapshot.launchCommand?.arguments ?? []
            let executable = normalized(snapshot.launchCommand?.executablePath)
                ?? arguments.first
                ?? registration.defaultExecutable
            guard normalized(executable) != nil else {
                return false
            }
        }
        return true
    }

    private static func launchCommandIdentityParts(
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String] {
        var parts = [
            "launcher=\(normalized(launchCommand?.launcher) ?? "")",
            "executable=\(normalized(launchCommand?.executablePath) ?? "")",
            "cwd=\(normalized(launchCommand?.workingDirectory) ?? "")",
        ]
        parts.append(contentsOf: (launchCommand?.arguments ?? []).map { "launchArg=\($0)" })
        parts.append(contentsOf: launchEnvironmentIdentityParts(kind: kind, environment: launchCommand?.environment))
        return parts
    }

    private static func launchEnvironmentIdentityParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else { return [] }

        var selectedEnvironment: [String: String] = [:]
        let policy = AgentLaunchEnvironmentPolicy()
        for key in environment.keys.sorted() {
            let value: String?
            if key == "CLAUDE_CONFIG_DIR" {
                value = normalized(environment[key])
            } else {
                value = policy.sanitizedValue(key: key, value: environment[key])
            }
            guard let value else { continue }
            selectedEnvironment[key] = value
        }
        let piFamilyUsesCapturedPath = kind == .pi
            || kind.customAgentID == "pi"
            || kind.customAgentID == "omp"
        if piFamilyUsesCapturedPath,
           let path = normalized(environment["PATH"]) {
            selectedEnvironment["PATH"] = path
        }
        return selectedEnvironment.keys.sorted().compactMap { key in
            selectedEnvironment[key].map { value in
                "env:\(key)=\(value)"
            }
        }
    }

    static func requiresLocalPiFamilyCapabilityProbe(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        switch snapshot.kind {
        case .pi:
            guard let registration = snapshot.registration else { return true }
            return registration.forkCommand == CmuxVaultAgentRegistration.builtInPi.forkCommand
        case .custom("pi"):
            return snapshot.registration?.forkCommand == CmuxVaultAgentRegistration.builtInPi.forkCommand
        case .custom("omp"):
            return snapshot.registration?.forkCommand == CmuxVaultAgentRegistration.builtInOmp.forkCommand
        default:
            return false
        }
    }

    private static func piFamilyProbeAgentID(_ snapshot: SessionRestorableAgentSnapshot) -> String {
        if let registrationID = normalizedPiFamilyAgentID(snapshot.registration?.id) {
            return registrationID
        }
        switch snapshot.kind {
        case .pi:
            return "pi"
        case .custom(let agentID):
            if let normalizedAgentID = normalizedPiFamilyAgentID(agentID) {
                return normalizedAgentID
            }
        default:
            break
        }
        let capturedLauncher = snapshot.launchCommand?.launcher?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let capturedExecutable = [
            snapshot.launchCommand?.executablePath,
            snapshot.launchCommand?.arguments.first,
        ]
            .compactMap { value in
                value.map { ($0 as NSString).lastPathComponent.lowercased() }
            }
            .first { $0 == "pi" || $0 == "omp" }
        let capturedLauncherID = capturedLauncher.flatMap {
            ["pi", "omp"].contains($0) ? $0 : nil
        }
        return capturedLauncherID
            ?? capturedExecutable
            ?? snapshot.registration?.id
            ?? snapshot.kind.rawValue
    }

    private static func normalizedPiFamilyAgentID(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "pi" || normalized == "omp" else { return nil }
        return normalized
    }

    private static func piFamilyProbeExecutableMatchesAgent(_ executable: String, agentID: String) -> Bool {
        let executableName = (executable as NSString).lastPathComponent.lowercased()
        switch agentID {
        case "pi":
            return executableName == "pi" || executableName == "pi-coding-agent"
        case "omp":
            return executableName == "omp"
        default:
            return false
        }
    }

    static func piFamilyVersionSupportsFork(
        _ output: String,
        agentID: String,
        acceptsBareVersionOutput: Bool = false
    ) -> Bool {
        guard let version = piFamilyProbeVersion(
            in: output,
            agentID: agentID,
            acceptsBareVersionOutput: acceptsBareVersionOutput
        ) else { return false }
        switch agentID {
        case "pi":
            return version >= minimumPiForkVersion
        case "omp":
            return version >= minimumOmpForkVersion
        default:
            return false
        }
    }

    private static func piFamilyProbeVersion(
        in output: String,
        agentID: String,
        acceptsBareVersionOutput: Bool
    ) -> SemanticVersion? {
        let normalizedAgentID = agentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedAgentID == "pi" || normalizedAgentID == "omp" else { return nil }

        var candidates: [SemanticVersion] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = line.lowercased()
            let isBareVersionLine = lowercasedLine.range(
                of: #"^v?\d+\.\d+(?:\.\d+)?$"#,
                options: .regularExpression
            ) != nil
            if acceptsBareVersionOutput && isBareVersionLine,
               let version = SemanticVersion.first(in: lowercasedLine) {
                candidates.append(version)
                continue
            }
            if let version = piFamilyVersionBoundToAgent(
                lowercasedLine,
                agentID: normalizedAgentID
            ) {
                candidates.append(version)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func piFamilyVersionBoundToAgent(_ line: String, agentID: String) -> SemanticVersion? {
        let escapedAgentID = NSRegularExpression.escapedPattern(for: agentID)
        let pattern = #"(^|[^a-z0-9])"# + escapedAgentID
            + #"([/\s:_-]+)v?(\d+)\.(\d+)(?:\.(\d+))?($|[^a-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { return nil }

        func integer(at captureIndex: Int, fallback defaultValue: Int? = nil) -> Int? {
            let captureRange = match.range(at: captureIndex)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: line) else {
                return defaultValue
            }
            return Int(line[range])
        }

        guard let major = integer(at: 3),
              let minor = integer(at: 4) else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: integer(at: 5, fallback: 0) ?? 0)
    }

    static func openCodeVersionSupportsFork(_ output: String) -> Bool {
        guard let version = SemanticVersion.first(in: output) else {
            return false
        }
        return version >= minimumOpenCodeForkVersion
    }

    private static func supportsLocalForkProbe(
        probe: (executable: String, arguments: [String]),
        snapshot: SessionRestorableAgentSnapshot,
        cacheDiscriminator: String,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool = false,
        usesOpenCodeVersionProbeCache: Bool = true,
        outputSupportsFork: @Sendable (String) -> Bool
    ) async -> Bool {
        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: snapshot.launchCommand?.environment)
        let usesDefaultDirectoryForMissingWorkingDirectory = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            && requestedWorkingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
        if usesDefaultDirectoryForMissingWorkingDirectory {
            return false
        }
        let workingDirectory = requestedWorkingDirectory
        switch localForkProbeDecision(probe: probe, workingDirectory: workingDirectory) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return true
        case .rejectMissingWorkingDirectory:
            return false
        case .rejectMissingExecutable:
            return false
        }
        let executableIdentity = forkProbeExecutableIdentity(
            executable: probe.executable,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory
        )
        let cacheKey = forkProbeCacheKey(
            probe: probe,
            processEnvironment: processEnvironment,
            executableIdentity: executableIdentity?.cachePart,
            workingDirectory: workingDirectory,
            discriminator: cacheDiscriminator
        )
        let probeStartedAt = Date().timeIntervalSinceReferenceDate
        if usesOpenCodeVersionProbeCache,
           executableIdentity != nil,
           let cached = await openCodeVersionProbeCache.value(for: cacheKey, now: probeStartedAt) {
            return cached
        }
        guard let output = await commandOutput(
            executable: probe.executable,
            arguments: probe.arguments,
            environment: snapshot.launchCommand?.environment,
            workingDirectory: workingDirectory
        ) else {
            return false
        }
        let supportsFork = outputSupportsFork(output)
        if executableIdentity != nil {
            let executableIdentityAfterProbe = forkProbeExecutableIdentity(
                executable: probe.executable,
                processEnvironment: processEnvironment,
                workingDirectory: workingDirectory
            )
            guard executableIdentityAfterProbe?.cachePart == executableIdentity?.cachePart else {
                return supportsFork
            }
        }
        if usesOpenCodeVersionProbeCache, executableIdentity != nil {
            await openCodeVersionProbeCache.store(supportsFork, for: cacheKey, now: probeStartedAt)
        }
        return supportsFork
    }

    private static func localForkProbeValidationIdentity(
        probe: (executable: String, arguments: [String]),
        snapshot: SessionRestorableAgentSnapshot,
        discriminator: String,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool = false
    ) -> String {
        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let workingDirectory = requestedWorkingDirectory
        let directoryPolicy = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            ? "default-directory-when-missing"
            : "requested-directory"
        return [
            directoryPolicy,
            forkProbeCacheKey(
                probe: probe,
                processEnvironment: processEnvironmentForOpenCodeProbeValidationIdentity(
                    environment: snapshot.launchCommand?.environment
                ),
                executableIdentity: nil,
                workingDirectory: workingDirectory,
                discriminator: discriminator
            ),
        ].joined(separator: "\u{1f}")
    }

    private static func forkProbeCacheKey(
        probe: (executable: String, arguments: [String]),
        processEnvironment: [String: String],
        executableIdentity: String?,
        workingDirectory: String?,
        discriminator: String
    ) -> String {
        let environmentParts = processEnvironment.keys.sorted().compactMap { key in
            processEnvironment[key].map { value in
                "\(key)=\(value)"
            }
        }
        return ([discriminator, probe.executable, "exec=\(executableIdentity ?? "unresolved")"] + probe.arguments + environmentParts + ["cwd=\(workingDirectory ?? "")"])
            .joined(separator: "\u{1f}")
    }

    private static func forkProbeExecutableIdentity(
        executable: String,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) -> (lookupPath: String, realPath: String, cachePart: String, watchDirectories: [String])? {
        guard let executableResolution = resolvedProbeExecutable(
            executable: executable,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory
        ) else {
            return nil
        }
        let executablePath = executableResolution.path
        var status = stat()
        guard stat(executablePath, &status) == 0 else {
            return nil
        }
        let realPath = realpath(executablePath, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? executablePath
        let cachePart = [
            realPath,
            "dev=\(status.st_dev)",
            "ino=\(status.st_ino)",
            "mode=\(status.st_mode)",
            "size=\(status.st_size)",
            "mtime=\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)",
            "ctime=\(status.st_ctimespec.tv_sec).\(status.st_ctimespec.tv_nsec)",
        ].joined(separator: ":")
        return (
            lookupPath: executablePath,
            realPath: realPath,
            cachePart: cachePart,
            watchDirectories: executableResolution.watchDirectories
        )
    }

    static func requiresForkValidationExecutableIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> Bool {
        guard !isRemoteContext else { return false }
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            return true
        }
        return snapshot.kind == .opencode
            && snapshot.launchCommand?.launcher != "omo"
            && AgentResumeCommandBuilder.openCodeVersionProbe(launchCommand: snapshot.launchCommand) != nil
    }

    static func forkValidationExecutableResolution(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> (status: String, lookupPath: String?, realPath: String?, cachePart: String?, watchDirectories: [String]) {
        guard requiresForkValidationExecutableIdentity(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) else { return ("notRequired", nil, nil, nil, []) }
        let fallbackExecutable: String
        let probe: (executable: String, arguments: [String])
        let useDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            useDefaultDirectoryWhenWorkingDirectoryIsMissing = true
        } else if snapshot.kind == .opencode,
                  snapshot.launchCommand?.launcher != "omo",
                  let openCodeProbe = AgentResumeCommandBuilder.openCodeVersionProbe(
                    launchCommand: snapshot.launchCommand
                  ) {
            probe = openCodeProbe
            useDefaultDirectoryWhenWorkingDirectoryIsMissing = false
        } else {
            return ("notRequired", nil, nil, nil, [])
        }

        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: snapshot.launchCommand?.environment)
        let usesDefaultDirectoryForMissingWorkingDirectory = useDefaultDirectoryWhenWorkingDirectoryIsMissing
            && requestedWorkingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
        if usesDefaultDirectoryForMissingWorkingDirectory {
            return ("unresolved", nil, nil, nil, [])
        }
        let workingDirectory = requestedWorkingDirectory
        switch localForkProbeDecision(probe: probe, workingDirectory: workingDirectory) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return ("skipRemoteLikeContext", nil, nil, nil, [])
        case .rejectMissingWorkingDirectory:
            return ("unresolved", nil, nil, nil, [])
        case .rejectMissingExecutable:
            return ("unresolved", nil, nil, nil, [])
        }
        guard let identity = forkProbeExecutableIdentity(
            executable: probe.executable,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory
        ) else {
            return ("unresolved", nil, nil, nil, [])
        }
        return ("resolved", identity.lookupPath, identity.realPath, identity.cachePart, identity.watchDirectories)
    }

    static func forkValidationExecutableIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> (lookupPath: String, realPath: String, cachePart: String)? {
        let resolution = forkValidationExecutableResolution(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        )
        guard resolution.status == "resolved",
              let lookupPath = resolution.lookupPath,
              let realPath = resolution.realPath,
              let cachePart = resolution.cachePart else {
            return nil
        }
        return (lookupPath, realPath, cachePart)
    }

    private static func resolvedProbeExecutable(
        executable: String,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) -> (path: String, watchDirectories: [String])? {
        let baseDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        func absolutePath(_ path: String) -> String {
            if path.hasPrefix("/") {
                return path
            }
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true))
                .standardizedFileURL
                .path
        }

        if executable.contains("/") {
            let path = absolutePath(executable)
            guard isRegularExecutableFile(atPath: path) else { return nil }
            return (path, [URL(fileURLWithPath: path).deletingLastPathComponent().path])
        }

        let pathDirectories = (processEnvironment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        var watchDirectories: [String] = []
        for directory in pathDirectories {
            let candidate = absolutePath((directory.isEmpty ? "." : directory) + "/" + executable)
            watchDirectories.append(URL(fileURLWithPath: candidate).deletingLastPathComponent().path)
            if isRegularExecutableFile(atPath: candidate) {
                return (candidate, watchDirectories)
            }
        }
        return nil
    }

    private static func isRegularExecutableFile(atPath path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        guard (status.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static func probeOutputPipeHandles(
        readFileDescriptor: Int32,
        writeFileDescriptor: Int32
    ) -> Set<UInt64> {
        var handles = Set<UInt64>()
        handles.formUnion(probeOutputPipeHandles(fileDescriptor: readFileDescriptor))
        handles.formUnion(probeOutputPipeHandles(fileDescriptor: writeFileDescriptor))
        return handles
    }

    private static func probeOutputPipeHandles(
        fileDescriptor: Int32,
        processIdentifier: pid_t = Darwin.getpid()
    ) -> Set<UInt64> {
        var pipeInfo = pipe_fdinfo()
        let byteCount = proc_pidfdinfo(
            Int32(processIdentifier),
            fileDescriptor,
            PROC_PIDFDPIPEINFO,
            &pipeInfo,
            Int32(MemoryLayout<pipe_fdinfo>.size)
        )
        guard byteCount == MemoryLayout<pipe_fdinfo>.size else {
            return []
        }
        return Set([
            pipeInfo.pipeinfo.pipe_handle,
            pipeInfo.pipeinfo.pipe_peerhandle,
        ].filter { $0 != 0 })
    }

    private static func processIdentifiersHoldingProbeOutputPipe(
        _ outputPipeHandles: Set<UInt64>,
        excluding excludedProcessIdentifiers: Set<pid_t>
    ) -> [pid_t] {
        guard !outputPipeHandles.isEmpty else { return [] }
        var processIdentifiers = [pid_t](repeating: 0, count: 8192)
        let returnedProcessIdentifierCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard returnedProcessIdentifierCount > 0 else { return [] }
        let processIdentifierCount = min(
            processIdentifiers.count,
            Int(returnedProcessIdentifierCount)
        )
        var matches: [pid_t] = []
        for processIdentifier in processIdentifiers.prefix(processIdentifierCount) where processIdentifier > 0 {
            guard !excludedProcessIdentifiers.contains(processIdentifier),
                  processHoldsProbeOutputPipe(processIdentifier, outputPipeHandles: outputPipeHandles) else {
                continue
            }
            matches.append(processIdentifier)
        }
        return matches
    }

    private static func processHoldsProbeOutputPipe(
        _ processIdentifier: pid_t,
        outputPipeHandles: Set<UInt64>
    ) -> Bool {
        var fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let fileDescriptorBytes = fileDescriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                Int32(processIdentifier),
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.size)
            )
        }
        guard fileDescriptorBytes > 0 else { return false }
        let fileDescriptorCount = min(
            fileDescriptors.count,
            Int(fileDescriptorBytes) / MemoryLayout<proc_fdinfo>.size
        )
        for fileDescriptorInfo in fileDescriptors.prefix(fileDescriptorCount)
        where fileDescriptorInfo.proc_fdtype == PROX_FDTYPE_PIPE {
            let handles = probeOutputPipeHandles(
                fileDescriptor: fileDescriptorInfo.proc_fd,
                processIdentifier: processIdentifier
            )
            if !handles.isDisjoint(with: outputPipeHandles) {
                return true
            }
        }
        return false
    }

    private static func commandOutput(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) async -> String? {
        let runner = CommandOutputRunner(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        return await withTaskCancellationHandler {
            await runner.start()
        } onCancel: {
            runner.cancel()
        }
    }

    static func processEnvironmentForOpenCodeProbe(
        environment: [String: String]?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = sanitizedBaseEnvironmentForOpenCodeProbe(baseEnvironment)
        if let environment {
            let selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment)
            for (key, value) in selectedEnvironment {
                processEnvironment[key] = value
            }
        }
        if let path = environment?["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processEnvironment["PATH"] = path
        } else if processEnvironment["PATH"] == nil {
            processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return processEnvironment
    }

    private static func processEnvironmentForOpenCodeProbeValidationIdentity(
        environment: [String: String]?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = sanitizedBaseEnvironmentForOpenCodeProbeValidationIdentity(baseEnvironment)
        if let environment {
            mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(environment, into: &processEnvironment)
        }
        if let path = environment?["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processEnvironment["PATH"] = path
        } else if processEnvironment["PATH"] == nil {
            processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return processEnvironment
    }

    private static func sanitizedBaseEnvironmentForOpenCodeProbe(_ environment: [String: String]) -> [String: String] {
        let safeBaseKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "TMPDIR",
            "USER"
        ]
        var processEnvironment: [String: String] = [:]
        for key in safeBaseKeys {
            guard let value = environment[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            processEnvironment[key] = value
        }
        let selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment)
        for (key, value) in selectedEnvironment {
            processEnvironment[key] = value
        }
        return processEnvironment
    }

    private static func sanitizedBaseEnvironmentForOpenCodeProbeValidationIdentity(
        _ environment: [String: String]
    ) -> [String: String] {
        let safeBaseKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "TMPDIR",
            "USER"
        ]
        var processEnvironment: [String: String] = [:]
        for key in safeBaseKeys {
            guard let value = environment[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            processEnvironment[key] = value
        }
        mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(environment, into: &processEnvironment)
        return processEnvironment
    }

    private static func mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(
        _ environment: [String: String],
        into processEnvironment: inout [String: String]
    ) {
        let policy = AgentLaunchEnvironmentPolicy()
        for key in environment.keys.sorted() {
            let value: String?
            if key == "CLAUDE_CONFIG_DIR" {
                value = normalized(environment[key])
            } else {
                value = policy.sanitizedValue(key: key, value: environment[key])
            }
            guard let value else { continue }
            processEnvironment[key] = value
        }
    }

    private static func probeWorkingDirectory(snapshot: SessionRestorableAgentSnapshot) -> String? {
        normalized(snapshot.workingDirectory) ?? normalized(snapshot.launchCommand?.workingDirectory)
    }

    private enum LocalForkProbeDecision {
        case run
        case skipRemoteLikeContext
        case rejectMissingWorkingDirectory
        case rejectMissingExecutable
    }

    private static func localForkProbeDecision(
        probe: (executable: String, arguments: [String]),
        workingDirectory: String?
    ) -> LocalForkProbeDecision {
        if let workingDirectory, localDirectoryURL(path: workingDirectory) == nil {
            return .rejectMissingWorkingDirectory
        }
        if probe.executable.hasPrefix("/") {
            return isRegularExecutableFile(atPath: probe.executable)
                ? .run
                : .rejectMissingExecutable
        }
        return .run
    }

    private static func localDirectoryURL(path: String?) -> URL? {
        guard let path = normalized(path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private actor OpenCodeVersionProbeCache {
    private let cache: AgentForkCapabilityProbeCache
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 30, maxEntries: Int = 128) {
        self.cache = AgentForkCapabilityProbeCache(maxEntries: maxEntries)
        self.ttl = ttl
    }

    func value(for key: String, now: TimeInterval) async -> Bool? {
        await cache.value(for: key, now: now)
    }

    func store(_ value: Bool, for key: String, now: TimeInterval) async {
        await cache.store(value, for: key, now: now, expiresAt: now + ttl)
    }
}

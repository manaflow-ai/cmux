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
    private static let piFamilyVersionProbeCache = AgentForkCapabilityProbeCache()
    private static let piFamilyVersionProbeCacheTTL: TimeInterval = 30

    private actor CommandOutputRunner {
        private let executable: String
        private let arguments: [String]
        private let environment: [String: String]?
        private let workingDirectory: String?
        private var process: Process?
        private var pipe: Pipe?
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            if let workingDirectoryURL = AgentForkSupport.localDirectoryURL(path: workingDirectory) {
                process.currentDirectoryURL = workingDirectoryURL
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = AgentForkSupport.processEnvironmentForOpenCodeProbe(environment: environment)
            process.terminationHandler = { [weak self] process in
                Task {
                    await self?.finish(exitStatus: process.terminationStatus)
                }
            }

            if completed || timedOut {
                completed = true
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            self.pipe = pipe

            startTimeoutTimer()

            do {
                try process.run()
            } catch {
                markFailedBeforeLaunch()
                return
            }

            if completed {
                process.terminationHandler = nil
                return
            }
            self.process = process
            try? pipe.fileHandleForWriting.close()
            let drain = CommandOutputDrain(
                readHandle: pipe.fileHandleForReading,
                maximumBytes: AgentForkSupport.commandOutputMaximumBytes
            )
            outputDrainTask = Task.detached(priority: .utility) {
                drain.run()
            }
            didLaunch = true

            if terminationRequested {
                if process.isRunning {
                    process.terminate()
                    startKillTimer(processIdentifier: process.processIdentifier)
                }
            }
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
            if waitingForOutputDrain {
                complete(returning: nil)
                return
            }
            guard didLaunch, let process else { return }
            guard process.isRunning else {
                complete(returning: nil)
                return
            }
            process.terminate()
            startKillTimer(processIdentifier: process.processIdentifier)
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
            guard !completed, process?.isRunning == true else { return }
            kill(processIdentifier, SIGKILL)
        }

        private func finish(exitStatus: Int32? = nil) {
            let process: Process?
            let killTimer: DispatchSourceTimer?
            let timedOut: Bool

            guard !completed else { return }
            process = self.process
            self.process = nil
            killTimer = self.killTimer
            self.killTimer = nil
            timedOut = self.timedOut

            killTimer?.cancel()
            process?.terminationHandler = nil

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
            let pipe: Pipe?
            let outputDrainTask: Task<Data, Never>?
            let process: Process?
            let timeoutTimer: DispatchSourceTimer?
            let killTimer: DispatchSourceTimer?

            guard !completed else { return }
            completed = true
            waitingForOutputDrain = false
            continuation = self.continuation
            self.continuation = nil
            pipe = self.pipe
            self.pipe = nil
            outputDrainTask = self.outputDrainTask
            self.outputDrainTask = nil
            process = self.process
            self.process = nil
            timeoutTimer = self.timeoutTimer
            self.timeoutTimer = nil
            killTimer = self.killTimer
            self.killTimer = nil

            timeoutTimer?.cancel()
            killTimer?.cancel()
            process?.terminationHandler = nil
            outputDrainTask?.cancel()
            try? pipe?.fileHandleForWriting.close()
            try? pipe?.fileHandleForReading.close()
            continuation?.resume(returning: result)
        }
    }

    /// Safety: `@unchecked Sendable` is scoped to the probe runner: one detached task
    /// consumes the read handle, and the actor may close that same handle only
    /// to break a blocked pipe read after the probe deadline. The handle never
    /// escapes to app state, and a timeout/close race only completes the probe
    /// as unsupported.
    // Safety: single detached reader; actor closes the pipe only to end a timed-out probe.
    private final class CommandOutputDrain: @unchecked Sendable {
        private let readHandle: FileHandle
        private let maximumBytes: Int

        init(readHandle: FileHandle, maximumBytes: Int) {
            self.readHandle = readHandle
            self.maximumBytes = maximumBytes
        }

        func run() -> Data {
            var output = Data()
            while true {
                let chunk = readHandle.readData(ofLength: 4096)
                guard !chunk.isEmpty else {
                    break
                }
                let remaining = maximumBytes - output.count
                if remaining > 0 {
                    output.append(contentsOf: chunk.prefix(remaining))
                }
            }
            try? readHandle.close()
            return output
        }
    }

    static func supportsFork(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) async -> Bool {
        guard snapshot.forkCommand != nil else { return false }
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
            return await supportsLocalForkProbe(
                probe: probe,
                snapshot: snapshot,
                cacheDiscriminator: "pi-family-version:\(agentID)",
                probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: true,
                boundedCacheTTL: piFamilyVersionProbeCacheTTL,
                outputSupportsFork: { output in
                    piFamilyVersionSupportsFork(output, agentID: agentID)
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
        guard let command = snapshot.forkCommand else { return nil }
        var parts = ["command", command]
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

    static func piFamilyVersionSupportsFork(_ output: String, agentID: String) -> Bool {
        guard let version = piFamilyProbeVersion(in: output, agentID: agentID) else { return false }
        switch agentID {
        case "pi":
            return version >= minimumPiForkVersion
        case "omp":
            return version >= minimumOmpForkVersion
        default:
            return false
        }
    }

    private static func piFamilyProbeVersion(in output: String, agentID: String) -> SemanticVersion? {
        let normalizedAgentID = agentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedAgentID == "pi" || normalizedAgentID == "omp" else { return nil }

        var candidates: [SemanticVersion] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = SemanticVersion.first(in: line) else { continue }
            let lowercasedLine = line.lowercased()
            if lowercasedLine.range(
                of: #"^v?\d+\.\d+(?:\.\d+)?$"#,
                options: .regularExpression
            ) != nil || piFamilyVersionLineMentionsAgent(lowercasedLine, agentID: normalizedAgentID) {
                candidates.append(version)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func piFamilyVersionLineMentionsAgent(_ line: String, agentID: String) -> Bool {
        line
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0 == agentID }
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
        boundedCacheTTL: TimeInterval? = nil,
        outputSupportsFork: @Sendable (String) -> Bool
    ) async -> Bool {
        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let workingDirectory = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            && requestedWorkingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
            ? nil
            : requestedWorkingDirectory
        switch localForkProbeDecision(probe: probe, workingDirectory: workingDirectory) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return true
        case .rejectMissingExecutable:
            return false
        }
        let cacheKey = forkProbeCacheKey(
            probe: probe,
            environment: snapshot.launchCommand?.environment,
            workingDirectory: workingDirectory,
            discriminator: cacheDiscriminator
        )
        let probeStartedAt = Date().timeIntervalSinceReferenceDate
        if boundedCacheTTL != nil {
            if let cached = await piFamilyVersionProbeCache.value(for: cacheKey, now: probeStartedAt) {
                return cached
            }
        } else if let cached = await openCodeVersionProbeCache.value(for: cacheKey, now: probeStartedAt) {
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
        if let boundedCacheTTL {
            await piFamilyVersionProbeCache.store(
                supportsFork,
                for: cacheKey,
                now: probeStartedAt,
                expiresAt: probeStartedAt + boundedCacheTTL
            )
        } else {
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
        let workingDirectory = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            && requestedWorkingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
            ? nil
            : requestedWorkingDirectory
        let decision = localForkProbeDecision(probe: probe, workingDirectory: workingDirectory)
        let decisionPart: String
        switch decision {
        case .run:
            decisionPart = "run"
        case .skipRemoteLikeContext:
            decisionPart = "skip-remote-like-context"
        case .rejectMissingExecutable:
            decisionPart = "reject-missing-executable"
        }
        return [
            decisionPart,
            forkProbeCacheKey(
                probe: probe,
                environment: snapshot.launchCommand?.environment,
                workingDirectory: workingDirectory,
                discriminator: discriminator
            ),
        ].joined(separator: "\u{1f}")
    }

    private static func forkProbeCacheKey(
        probe: (executable: String, arguments: [String]),
        environment: [String: String]?,
        workingDirectory: String?,
        discriminator: String
    ) -> String {
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: environment)
        let environmentParts = processEnvironment.keys.sorted().compactMap { key in
            processEnvironment[key].map { value in
                "\(key)=\(value)"
            }
        }
        return ([discriminator, probe.executable] + probe.arguments + environmentParts + ["cwd=\(workingDirectory ?? "")"])
            .joined(separator: "\u{1f}")
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

    private static func probeWorkingDirectory(snapshot: SessionRestorableAgentSnapshot) -> String? {
        normalized(snapshot.launchCommand?.workingDirectory) ?? normalized(snapshot.workingDirectory)
    }

    private enum LocalForkProbeDecision {
        case run
        case skipRemoteLikeContext
        case rejectMissingExecutable
    }

    private static func localForkProbeDecision(
        probe: (executable: String, arguments: [String]),
        workingDirectory: String?
    ) -> LocalForkProbeDecision {
        if let workingDirectory, localDirectoryURL(path: workingDirectory) == nil {
            return .skipRemoteLikeContext
        }
        if probe.executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: probe.executable)
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

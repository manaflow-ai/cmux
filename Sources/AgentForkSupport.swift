import CmuxFoundation
import Foundation
import CMUXAgentLaunch
import Darwin

/// Coordinates cancellation with `Process.run()`: Foundation raises an
/// Objective-C exception if termination APIs touch a task before launch.
/// `@unchecked Sendable` is safe here because all mutable state is protected by `lock`.
final class ProcessTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didLaunch = false
    private var didFinish = false
    private var terminationRequested = false

    func requestTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        terminationRequested = true
        return didLaunch
    }

    func markLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didLaunch = true
        return terminationRequested
    }

    func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        didFinish = true
    }
}

private actor OpenCodeVersionProbeCache {
    private var valuesByKey: [String: Bool] = [:]

    func value(for key: String) -> Bool? {
        valuesByKey[key]
    }

    func store(_ value: Bool, for key: String) {
        valuesByKey[key] = value
    }
}

enum AgentForkSupport {
    static let minimumOpenCodeForkVersion = SemanticVersion(major: 1, minor: 14, patch: 50)
    private static let commandOutputTimeoutNanoseconds: Int64 = 3_000_000_000
    private static let commandTerminateTimeoutNanoseconds: Int64 = 500_000_000
    private static let openCodeVersionProbeCache = OpenCodeVersionProbeCache()

    private final class CommandOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return snapshot
        }
    }

    private final class CommandOutputRunner: @unchecked Sendable {
        private let executable: String
        private let arguments: [String]
        private let environment: [String: String]?
        private let workingDirectory: String?
        private let outputBuffer = CommandOutputBuffer()
        private let lock = NSLock()
        private var process: Process?
        private var pipe: Pipe?
        private var timeoutTimer: DispatchSourceTimer?
        private var killTimer: DispatchSourceTimer?
        private var continuation: CheckedContinuation<String?, Never>?
        private let terminationGate = ProcessTerminationGate()
        private var completed = false
        private var timedOut = false

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
            pipe.fileHandleForReading.readabilityHandler = { [outputBuffer] handle in
                switch handle.readAvailableDataOrEndOfFile() {
                case .data(let data):
                    outputBuffer.append(data)
                case .wouldBlock:
                    return
                case .endOfFile:
                    handle.readabilityHandler = nil
                }
            }
            process.environment = AgentForkSupport.processEnvironmentForOpenCodeProbe(environment: environment)
            process.terminationHandler = { [weak self] _ in
                self?.finish()
            }

            lock.lock()
            if completed || timedOut {
                completed = true
                lock.unlock()
                terminationGate.markFinished()
                pipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            self.pipe = pipe
            lock.unlock()

            startTimeoutTimer()

            do {
                try process.run()
            } catch {
                terminationGate.markFinished()
                markFailedBeforeLaunch()
                return
            }

            lock.lock()
            if completed {
                lock.unlock()
                terminationGate.markFinished()
                process.terminationHandler = nil
                return
            }
            self.process = process
            lock.unlock()

            if terminationGate.markLaunched() {
                if process.isRunning {
                    process.terminate()
                    startKillTimer(processIdentifier: process.processIdentifier)
                }
            }
        }

        func cancel() {
            markTimedOutAndTerminate()
        }

        private func startTimeoutTimer() {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .nanoseconds(Int(AgentForkSupport.commandOutputTimeoutNanoseconds)))
            timer.setEventHandler { [self] in
                markTimedOutAndTerminate()
            }
            lock.lock()
            if completed {
                lock.unlock()
                timer.resume()
                timer.cancel()
                return
            }
            timeoutTimer = timer
            lock.unlock()
            timer.resume()
        }

        private func markFailedBeforeLaunch() {
            lock.lock()
            timedOut = true
            lock.unlock()
            finish()
        }

        private func markTimedOutAndTerminate() {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            timedOut = true
            lock.unlock()

            guard terminationGate.requestTermination() else {
                return
            }
            let process: Process?
            lock.lock()
            process = self.process
            lock.unlock()
            guard let process else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
            startKillTimer(processIdentifier: process.processIdentifier)
        }

        private func startKillTimer(processIdentifier: pid_t) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .nanoseconds(Int(AgentForkSupport.commandTerminateTimeoutNanoseconds)))
            timer.setEventHandler { [self] in
                lock.lock()
                let shouldKill = !completed && process?.isRunning == true
                lock.unlock()
                if shouldKill {
                    kill(processIdentifier, SIGKILL)
                }
            }
            lock.lock()
            if completed {
                lock.unlock()
                timer.resume()
                timer.cancel()
                return
            }
            killTimer?.cancel()
            killTimer = timer
            lock.unlock()
            timer.resume()
        }

        private func finish() {
            let continuation: CheckedContinuation<String?, Never>?
            let pipe: Pipe?
            let process: Process?
            let timeoutTimer: DispatchSourceTimer?
            let killTimer: DispatchSourceTimer?
            let timedOut: Bool

            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            pipe = self.pipe
            self.pipe = nil
            process = self.process
            self.process = nil
            timeoutTimer = self.timeoutTimer
            self.timeoutTimer = nil
            killTimer = self.killTimer
            self.killTimer = nil
            timedOut = self.timedOut
            lock.unlock()

            terminationGate.markFinished()
            timeoutTimer?.cancel()
            killTimer?.cancel()
            process?.terminationHandler = nil
            pipe?.fileHandleForReading.readabilityHandler = nil
            if let readHandle = pipe?.fileHandleForReading {
                let remainingData = readHandle.readDataToEndOfFileOrEmpty()
                outputBuffer.append(remainingData)
            }
            guard !timedOut else {
                continuation?.resume(returning: nil)
                return
            }
            continuation?.resume(returning: String(data: outputBuffer.value(), encoding: .utf8))
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
        guard snapshot.kind == .opencode else { return true }
        if snapshot.launchCommand?.launcher == "omo" {
            return true
        }
        if isRemoteContext {
            return true
        }
        guard let probe = AgentResumeCommandBuilder().openCodeVersionProbe(
            launchCommand: snapshot.launchCommand
        ) else {
            return false
        }
        let workingDirectory = openCodeProbeWorkingDirectory(snapshot: snapshot)
        switch localOpenCodeVersionProbeDecision(
            probe: probe,
            workingDirectory: workingDirectory
        ) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return true
        case .rejectMissingExecutable:
            return false
        }
        let cacheKey = openCodeVersionProbeCacheKey(
            probe: probe,
            environment: snapshot.launchCommand?.environment,
            workingDirectory: workingDirectory
        )
        if let cached = await openCodeVersionProbeCache.value(for: cacheKey) {
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
        let supportsFork = openCodeVersionSupportsFork(output)
        await openCodeVersionProbeCache.store(supportsFork, for: cacheKey)
        return supportsFork
    }

    static func openCodeVersionSupportsFork(_ output: String) -> Bool {
        guard let version = SemanticVersion.first(in: output) else {
            return false
        }
        return version >= minimumOpenCodeForkVersion
    }

    private static func openCodeVersionProbeCacheKey(
        probe: (executable: String, arguments: [String]),
        environment: [String: String]?,
        workingDirectory: String?
    ) -> String {
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: environment)
        let relevantEnvironmentKeys = [
            "PATH",
            "OPENCODE_BIN",
            "OPENCODE_CONFIG_DIR"
        ]
        let environmentParts = relevantEnvironmentKeys.map { key in
            "\(key)=\(processEnvironment[key] ?? "")"
        }
        return ([probe.executable] + probe.arguments + environmentParts + ["cwd=\(workingDirectory ?? "")"])
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
            await withCheckedContinuation { continuation in
                runner.start(continuation: continuation)
            }
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
            let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
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
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        for (key, value) in selectedEnvironment {
            processEnvironment[key] = value
        }
        return processEnvironment
    }

    private static func openCodeProbeWorkingDirectory(snapshot: SessionRestorableAgentSnapshot) -> String? {
        normalized(snapshot.launchCommand?.workingDirectory) ?? normalized(snapshot.workingDirectory)
    }

    private enum LocalOpenCodeVersionProbeDecision {
        case run
        case skipRemoteLikeContext
        case rejectMissingExecutable
    }

    private static func localOpenCodeVersionProbeDecision(
        probe: (executable: String, arguments: [String]),
        workingDirectory: String?
    ) -> LocalOpenCodeVersionProbeDecision {
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

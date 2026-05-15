import Foundation
import CMUXAgentLaunch
import Darwin

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
        guard let probe = AgentResumeCommandBuilder.openCodeVersionProbe(
            launchCommand: snapshot.launchCommand
        ) else {
            return false
        }
        let workingDirectory = openCodeProbeWorkingDirectory(snapshot: snapshot)
        guard shouldRunLocalOpenCodeVersionProbe(
            probe: probe,
            workingDirectory: workingDirectory
        ) else {
            return true
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
        if supportsFork {
            await openCodeVersionProbeCache.store(supportsFork, for: cacheKey)
        }
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
        await Task.detached(priority: .utility) {
            commandOutputSynchronously(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        }.value
    }

    private static func commandOutputSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let workingDirectoryURL = localDirectoryURL(path: workingDirectory) {
            process.currentDirectoryURL = workingDirectoryURL
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outputBuffer = CommandOutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        process.environment = processEnvironmentForOpenCodeProbe(environment: environment)
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        var timedOut = false
        if completion.wait(timeout: .now() + .nanoseconds(Int(commandOutputTimeoutNanoseconds))) == .timedOut {
            timedOut = true
            process.terminate()
            if completion.wait(timeout: .now() + .nanoseconds(Int(commandTerminateTimeoutNanoseconds))) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                completion.wait()
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        outputBuffer.append(remainingData)
        guard !timedOut else { return nil }
        return String(data: outputBuffer.value(), encoding: .utf8)
    }

    private static func processEnvironmentForOpenCodeProbe(environment: [String: String]?) -> [String: String] {
        var processEnvironment = ProcessInfo.processInfo.environment
        guard let environment else { return processEnvironment }
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        for (key, value) in selectedEnvironment {
            processEnvironment[key] = value
        }
        if let path = environment["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processEnvironment["PATH"] = path
        }
        return processEnvironment
    }

    private static func openCodeProbeWorkingDirectory(snapshot: SessionRestorableAgentSnapshot) -> String? {
        normalized(snapshot.launchCommand?.workingDirectory) ?? normalized(snapshot.workingDirectory)
    }

    private static func shouldRunLocalOpenCodeVersionProbe(
        probe: (executable: String, arguments: [String]),
        workingDirectory: String?
    ) -> Bool {
        if let workingDirectory, localDirectoryURL(path: workingDirectory) == nil {
            return false
        }
        if probe.executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: probe.executable)
        }
        return true
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

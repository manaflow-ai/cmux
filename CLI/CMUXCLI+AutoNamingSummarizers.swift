import Darwin
import Foundation

extension CMUXCLI {
    func runAutoNamingSummarizer(
        def: AgentHookDef,
        prompt: String,
        env: [String: String],
        timeout: TimeInterval,
        telemetry: CLISocketSentryTelemetry
    ) -> String? {
        let policy = AutoNamingEnvironmentPolicy()
        // Generic agents (grok/opencode/pi/omp) need their OWN provider/cloud
        // credentials to authenticate, so — unlike Codex's tight allowlist — we
        // use the broad scrubbed env here. Exposure is bounded by running the
        // summarizer with tools and network disabled (see the per-agent argv:
        // --pure / --no-tools / --disable-web-search / --no-subagents), so the
        // untrusted transcript text has no channel to exfiltrate those vars.
        var summarizerEnv = policy.summarizerEnvironment(from: env)
        summarizerEnv[def.disableEnvVar] = "1"

        func executable(_ name: String = def.binaryName) -> String? {
            resolveExecutableInSearchPath(name, searchPath: env["PATH"])
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autoname-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        func promptFile() -> String? {
            let url = tempRoot.appendingPathComponent("prompt.txt", isDirectory: false)
            guard let data = prompt.data(using: .utf8) else { return nil }
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [
                .posixPermissions: NSNumber(value: Int16(0o600))
            ]) else { return nil }
            return url.path
        }

        let executablePath: String?
        let arguments: [String]
        let stdinPrompt: String
        switch def.name {
        case "opencode":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable("opencode")
            arguments = [
                "run",
                "--pure",
                "--format", "default",
                "--dir", tempRoot.path,
                "--file", promptPath,
                "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
            ]
            stdinPrompt = ""
        case "grok":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable("grok")
            arguments = [
                "--prompt-file", promptPath,
                "--output-format", "plain",
                "--tools", "",
                "--disable-web-search",
                "--no-subagents",
                "--no-memory",
                "--verbatim"
            ]
            stdinPrompt = ""
        case "pi", "omp":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable()
            arguments = [
                "--print",
                "--no-tools",
                "--no-session",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-context-files",
                "@\(promptPath)",
                "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
            ]
            stdinPrompt = ""
        default:
            return nil
        }

        guard let executablePath else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.no-binary")
            return nil
        }
        return runAutoNamingSummarizer(
            executable: executablePath,
            arguments: arguments,
            prompt: stdinPrompt,
            environment: summarizerEnv,
            timeout: timeout
        )
    }

    /// Returns a cheap monotonic progress metric for file-backed transcripts.
    /// File size preserves growth and compaction/shrink signals without
    /// streaming the whole transcript on every naming pass.
    func textFileGrowthMetric(path: String, fallbackLineCount: Int) -> Int {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath),
              let size = attributes[.size] as? NSNumber else {
            return fallbackLineCount
        }
        return max(fallbackLineCount, size.intValue / 128)
    }

    /// Runs the summarizer subprocess with the prompt on stdin and a hard
    /// deadline, returning bounded stdout (nil on failure, timeout, oversized
    /// output, or non-zero exit). stdout is captured through a pipe with a live
    /// byte cap, then the read side is closed on return so inherited writer fds
    /// cannot keep the hook blocked after the main summarizer exits.
    func runAutoNamingSummarizer(
        executable: String,
        arguments: [String],
        prompt: String,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stdoutBuffer = AutoNamingOutputCapture()
        let maxOutputBytes = 64 * 1024
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let available = handle.availableData
            guard !available.isEmpty else { return }
            if !stdoutBuffer.append(available, maxBytes: maxOutputBytes), process.isRunning {
                process.terminate()
            }
        }

        do {
            try cliRunProcess(process)
        } catch {
            return nil
        }
        if let promptData = prompt.data(using: .utf8) {
            _ = cliWrite(promptData, to: stdinPipe.fileHandleForWriting, onBrokenPipe: .ignore)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let exited = (try? waitForProcessExit(process, timeout: timeout)) ?? false
        if !exited {
            process.terminate()
            if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = try? waitForProcessExit(process, timeout: 1)
            }
            return nil
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        drainAvailableAutoNamingOutput(
            from: stdoutPipe.fileHandleForReading.fileDescriptor,
            into: stdoutBuffer,
            maxBytes: maxOutputBytes,
            process: process
        )
        guard process.terminationStatus == 0,
              let output = stdoutBuffer.dataIfWithinLimit() else {
            return nil
        }
        return String(data: output, encoding: .utf8)
    }

    private func drainAvailableAutoNamingOutput(
        from fd: Int32,
        into buffer: AutoNamingOutputCapture,
        maxBytes: Int,
        process: Process
    ) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        defer {
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags)
            }
        }

        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let readCount = Darwin.read(fd, &chunk, chunk.count)
            if readCount > 0 {
                let data = Data(chunk.prefix(readCount))
                if !buffer.append(data, maxBytes: maxBytes), process.isRunning {
                    process.terminate()
                }
                continue
            }
            if readCount == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            return
        }
    }
}

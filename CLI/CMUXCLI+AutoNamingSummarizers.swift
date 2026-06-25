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
    /// deadline, returning captured stdout (nil on failure, timeout, or
    /// non-zero exit). On any failure path `onFailure` receives a category, the
    /// process exit status (when known), and a bounded tail of the subprocess
    /// stderr. The summarizer runs detached with its fds pointed at /dev/null,
    /// so this callback is the only way a failure reason (e.g. an invalid
    /// `--mcp-config` payload) escapes — without it, a broken summarizer leaves
    /// workspaces silently unnamed.
    func runAutoNamingSummarizer(
        executable: String,
        arguments: [String],
        prompt: String,
        environment: [String: String],
        timeout: TimeInterval,
        onFailure: ((_ reason: String, _ exitStatus: Int32?, _ stderrTail: String) -> Void)? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdinPipe = Pipe()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autoname-stdout-\(UUID().uuidString).txt")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autoname-stderr-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let stdoutHandle = try? FileHandle(forWritingTo: outputURL),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            onFailure?("spawn-setup", nil, "")
            return nil
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        func stderrTail() -> String {
            try? stderrHandle.close()
            guard let data = try? Data(contentsOf: stderrURL),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
        }

        do {
            try cliRunProcess(process)
        } catch {
            onFailure?("spawn-failed", nil, "\(error)")
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
            onFailure?("timeout", nil, stderrTail())
            return nil
        }
        try? stdoutHandle.close()
        guard process.terminationStatus == 0 else {
            onFailure?("nonzero-exit", process.terminationStatus, stderrTail())
            return nil
        }
        guard let output = try? Data(contentsOf: outputURL) else {
            onFailure?("no-output", 0, stderrTail())
            return nil
        }
        return String(data: output, encoding: .utf8)
    }
}

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
        var stdinFDs = [Int32](repeating: -1, count: 2)
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        defer {
            for fd in stdinFDs + stdoutFDs where fd >= 0 {
                close(fd)
            }
        }
        guard pipe(&stdinFDs) == 0,
              pipe(&stdoutFDs) == 0 else {
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(&fileActions, stdinFDs[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO) == 0 else {
            return nil
        }
        let stderrResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, path, O_WRONLY, 0)
        }
        guard stderrResult == 0 else { return nil }
        for fd in stdinFDs + stdoutFDs {
            guard posix_spawn_file_actions_addclose(&fileActions, fd) == 0 else { return nil }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var spawnedPID: pid_t = 0
        let spawnResult = withAutoNamingCStringArray(argv) { cArgv in
            withAutoNamingCStringArray(envp) { cEnvp in
                executable.withCString { executablePath in
                    posix_spawn(&spawnedPID, executablePath, &fileActions, &attributes, cArgv, cEnvp)
                }
            }
        }
        guard spawnResult == 0, spawnedPID > 0 else { return nil }

        close(stdinFDs[0])
        stdinFDs[0] = -1
        close(stdoutFDs[1])
        stdoutFDs[1] = -1

        let maxOutputBytes = 64 * 1024
        let promptData = prompt.data(using: .utf8) ?? Data()
        configureCLIWriteFDNoSIGPIPE(stdinFDs[1])
        let stdinFlags = fcntl(stdinFDs[1], F_GETFL, 0)
        if stdinFlags >= 0 {
            _ = fcntl(stdinFDs[1], F_SETFL, stdinFlags | O_NONBLOCK)
        }
        let stdoutFD = stdoutFDs[0]
        let stdoutFlags = fcntl(stdoutFD, F_GETFL, 0)
        if stdoutFlags >= 0 {
            _ = fcntl(stdoutFD, F_SETFL, stdoutFlags | O_NONBLOCK)
        }
        defer {
            if stdoutFlags >= 0 {
                _ = fcntl(stdoutFD, F_SETFL, stdoutFlags)
            }
        }

        var output = Data()
        let firstWait = waitForAutoNamingProcess(
            pid: spawnedPID,
            stdinFD: &stdinFDs[1],
            promptData: promptData,
            stdoutFD: stdoutFD,
            output: &output,
            maxBytes: maxOutputBytes,
            timeout: timeout
        )
        closeAutoNamingFD(&stdinFDs[1])
        guard firstWait.outputWithinLimit else {
            terminateAutoNamingProcessGroup(pid: spawnedPID, stdoutFD: stdoutFD, output: &output, maxBytes: maxOutputBytes)
            return nil
        }
        guard firstWait.promptDelivered else {
            terminateAutoNamingProcessGroup(pid: spawnedPID, stdoutFD: stdoutFD, output: &output, maxBytes: maxOutputBytes)
            return nil
        }
        guard let rawStatus = firstWait.rawStatus else {
            terminateAutoNamingProcessGroup(pid: spawnedPID, stdoutFD: stdoutFD, output: &output, maxBytes: maxOutputBytes)
            return nil
        }
        guard normalizedAutoNamingTerminationStatus(rawStatus) == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }

    @discardableResult
    private func terminateAutoNamingProcessGroup(
        pid: pid_t,
        stdoutFD: Int32,
        output: inout Data,
        maxBytes: Int
    ) -> Int32? {
        signalAutoNamingProcessGroup(pid: pid, signal: SIGTERM)
        var noStdin: Int32 = -1
        let terminated = waitForAutoNamingProcess(
            pid: pid,
            stdinFD: &noStdin,
            promptData: Data(),
            stdoutFD: stdoutFD,
            output: &output,
            maxBytes: maxBytes,
            timeout: 2
        )
        if let rawStatus = terminated.rawStatus { return rawStatus }
        signalAutoNamingProcessGroup(pid: pid, signal: SIGKILL)
        noStdin = -1
        return waitForAutoNamingProcess(
            pid: pid,
            stdinFD: &noStdin,
            promptData: Data(),
            stdoutFD: stdoutFD,
            output: &output,
            maxBytes: maxBytes,
            timeout: 1
        ).rawStatus
    }

    private func waitForAutoNamingProcess(
        pid: pid_t,
        stdinFD: inout Int32,
        promptData: Data,
        stdoutFD: Int32,
        output: inout Data,
        maxBytes: Int,
        timeout: TimeInterval
    ) -> (rawStatus: Int32?, outputWithinLimit: Bool, promptDelivered: Bool) {
        var stdoutEOF = false
        var promptOffset = 0
        var promptDelivered = promptData.isEmpty
        var reapedStatus: Int32?
        let deadline = Date().addingTimeInterval(timeout)
        if promptDelivered {
            closeAutoNamingFD(&stdinFD)
        }
        while true {
            if reapedStatus == nil {
                reapedStatus = reapAutoNamingProcessIfExited(pid: pid)
            }
            if !stdoutEOF {
                let withinLimit = drainAvailableAutoNamingOutput(
                    from: stdoutFD,
                    into: &output,
                    maxBytes: maxBytes,
                    reachedEOF: &stdoutEOF
                )
                guard withinLimit else { return (nil, false, promptDelivered) }
            }
            if !promptDelivered {
                let writeResult = writeAvailableAutoNamingInput(promptData, offset: &promptOffset, to: stdinFD)
                if writeResult.completed {
                    promptDelivered = true
                    closeAutoNamingFD(&stdinFD)
                } else if writeResult.failed {
                    closeAutoNamingFD(&stdinFD)
                    return (nil, true, false)
                }
            }
            if reapedStatus == nil {
                reapedStatus = reapAutoNamingProcessIfExited(pid: pid)
            }
            if let rawStatus = reapedStatus {
                guard promptDelivered else {
                    closeAutoNamingFD(&stdinFD)
                    return (nil, true, false)
                }
                if !stdoutEOF {
                    let withinLimit = drainAvailableAutoNamingOutput(
                        from: stdoutFD,
                        into: &output,
                        maxBytes: maxBytes,
                        reachedEOF: &stdoutEOF
                    )
                    guard withinLimit else { return (nil, false, true) }
                }
                return (rawStatus, true, true)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (nil, true, promptDelivered) }
            if stdoutEOF && promptDelivered {
                waitForAutoNamingProcessExitEvent(pid: pid, timeout: min(remaining, 0.25))
            } else {
                waitForAutoNamingPipeChange(
                    stdoutFD: stdoutEOF ? nil : stdoutFD,
                    stdinFD: promptDelivered ? nil : stdinFD,
                    timeout: min(remaining, 0.25)
                )
            }
        }
    }

    private func closeAutoNamingFD(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func writeAvailableAutoNamingInput(
        _ data: Data,
        offset: inout Int,
        to fd: Int32
    ) -> (completed: Bool, failed: Bool) {
        guard fd >= 0 else { return (false, true) }
        guard !data.isEmpty else { return (true, false) }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return (true, false)
            }
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return (false, true) }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return (false, false)
                default:
                    return (false, true)
                }
            }
            return (true, false)
        }
    }

    private func drainAvailableAutoNamingOutput(
        from fd: Int32,
        into output: inout Data,
        maxBytes: Int,
        reachedEOF: inout Bool
    ) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let readCount = Darwin.read(fd, &chunk, chunk.count)
            if readCount > 0 {
                guard output.count + readCount <= maxBytes else {
                    output.removeAll(keepingCapacity: false)
                    return false
                }
                output.append(contentsOf: chunk.prefix(readCount))
                continue
            }
            if readCount == 0 {
                reachedEOF = true
                return true
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
    }

    private func reapAutoNamingProcessIfExited(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1 && errno == EINTR { continue }
            if result == -1 && errno == ECHILD { return 0 }
            return nil
        }
    }

    private func normalizedAutoNamingTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal != 0 { return 128 + signal }
        return (rawStatus >> 8) & 0xff
    }

    private func signalAutoNamingProcessGroup(pid: pid_t, signal: Int32) {
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
    }

    private func waitForAutoNamingProcessExitEvent(pid: pid_t, timeout: TimeInterval) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var registrationEvent = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD) | UInt16(EV_ENABLE) | UInt16(EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        var exitEvent = kevent()
        var timeoutSpec = autoNamingTimespec(timeout)
        _ = kevent(queue, &registrationEvent, 1, &exitEvent, 1, &timeoutSpec)
    }

    private func waitForAutoNamingPipeChange(stdoutFD: Int32?, stdinFD: Int32?, timeout: TimeInterval) {
        var descriptors: [pollfd] = []
        if let stdoutFD {
            descriptors.append(pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
        }
        if let stdinFD {
            descriptors.append(pollfd(fd: stdinFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0))
        }
        guard !descriptors.isEmpty else { return }
        let timeoutMilliseconds = max(0, Int32((timeout * 1_000).rounded(.up)))
        while true {
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
            }
            if result >= 0 { return }
            if errno == EINTR { continue }
            return
        }
    }

    private func autoNamingTimespec(_ timeout: TimeInterval) -> timespec {
        let clamped = max(0, timeout)
        let seconds = Int(clamped)
        let nanoseconds = Int((clamped - TimeInterval(seconds)) * 1_000_000_000)
        return timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    }

    private func withAutoNamingCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

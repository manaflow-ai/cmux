import Foundation

// `cmux chief dispatch`: one new workspace with one coding agent working on
// one task. Parsing, the launcher script and the screen check live in
// `ChiefDispatchPlan.swift`; this file does the I/O.
extension CMUXCLI {
    static let chiefDispatchUsage = String(
        localized: "cli.chief.dispatch.usage",
        defaultValue: """
        Usage: cmux chief dispatch [--agent codex|claude] [--name <title>] [--cwd <dir>]
                                   [--worktree <repo> [--branch <name>]] [--agent-arg <arg>]...
                                   [--focus|--no-focus] [--wait-working [--timeout <seconds>]] [--json]
                                   (-- <task words...> | --prompt-file <path|->)

        Start one coding agent on one task in a new workspace. The workspace is titled
        --name (default: the task's first line) and has no description.

        The task is passed to the agent as one argument and never through a shell, so
        quotes, $ and newlines arrive unchanged. --prompt-file - reads it from stdin.
        The task is the agent's last command-line argument, so `ps` and other tools
        on this Mac can show it while the agent runs. Keep secrets out of it.

        Options:
          --agent codex|claude   Default codex, started with normal permission prompts.
          --agent-arg <arg>      Append one argument to the agent's command (repeatable).
                               Add `--agent-arg --yolo` only when the user explicitly enabled
                               Chief's dangerous permission bypass setting.
          --cwd <dir>            The agent's directory (default: the app's default).
          --worktree <repo>      First run `git -C <repo> worktree add -b <branch> <repo>-<slug>`
                                 and start the agent there. <slug> comes from the title.
          --branch <name>        The new branch for --worktree (default: <slug>).
          --focus, --no-focus    Switch to the new workspace, or stay where you are. By default it
                                 switches only when a person runs the command in a terminal.
          --wait-working         Wait until the terminal shows the agent working
                                 (Codex "Working (…)", a Claude Code spinner row).
          --timeout <seconds>    How long --wait-working waits (default 60, max 600).
          --json                 Print workspace_id, workspace_ref, surface_id, agent and status.

        status is working (seen working), started (not checked) or failed (with a reason:
        timeout, trust_prompt, sign_in or agent_not_found). A failed check exits 1.

        Examples:
          cmux chief dispatch --agent codex --name "#123: fix login" --cwd ~/src/app --wait-working -- 'Fix the login bug and open a PR.'
          cmux chief dispatch --agent claude --worktree ~/src/app --wait-working --prompt-file task.md
        """
    )

    func runChiefDispatchCommand(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?
    ) throws {
        if ChiefDispatchOptions.isHelpRequest(args) {
            print(Self.chiefDispatchUsage)
            return
        }
        let options = try ChiefDispatchOptions.parse(args)
        let rawPrompt: String
        switch options.prompt {
        case let .words(text):
            rawPrompt = text
        case .standardInput:
            rawPrompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        case let .file(path):
            guard let data = FileManager.default.contents(atPath: resolvePath(path)) else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.chief.dispatch.error.promptFileUnreadable",
                        defaultValue: "Couldn't read the task file %@."
                    ),
                    path
                ))
            }
            rawPrompt = String(decoding: data, as: UTF8.self)
        }
        let prompt = try ChiefDispatchOptions.normalizedPrompt(rawPrompt)
        let title = options.title(prompt: prompt)

        var directory = options.cwd.map { resolvePath($0) }
        var worktree: (path: String, branch: String)?
        if let repo = options.worktreeRepo.map({ resolvePath($0) }) {
            let slug = ChiefDispatchPlan.slug(options.branch ?? title)
            let branch = options.branch ?? slug
            let path = ChiefDispatchPlan.worktreePath(repo: repo, slug: slug)
            try Self.addChiefDispatchWorktree(repo: repo, path: path, branch: branch)
            worktree = (path, branch)
            directory = path
        }

        let launcher = try Self.writeChiefDispatchLauncher(agentCommand: options.agentCommand, prompt: prompt)
        var params: [String: Any] = [
            "title": title,
            "initial_input": ChiefDispatchPlan.typedCommand(launcherPath: launcher.script) + "\r",
            "focus": options.focus ?? Self.defaultFocusForUserOpen(),
        ]
        if let directory { params["cwd"] = directory }
        let response: [String: Any]
        do {
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowOverride)
            response = try client.sendV2(method: "workspace.create", params: params)
        } catch {
            // The launcher never ran, so the task file is still on disk.
            try? FileManager.default.removeItem(atPath: launcher.directory)
            throw error
        }

        let workspaceID = response["workspace_id"] as? String ?? ""
        let workspaceRef = response["workspace_ref"] as? String ?? workspaceID
        let surfaceID = response["surface_id"] as? String
        var result: [String: Any] = [
            "workspace_id": workspaceID,
            "workspace_ref": workspaceRef,
            "surface_id": surfaceID ?? NSNull(),
            "surface_ref": response["surface_ref"] as? String ?? NSNull(),
            "agent": options.agent.rawValue,
            "title": title,
            "cwd": directory ?? NSNull(),
            "status": "started",
        ]
        if let worktree {
            result["worktree"] = worktree.path
            result["branch"] = worktree.branch
        }

        var failure: String?
        if options.waitWorking {
            switch try waitForChiefDispatchAgent(
                agent: options.agent, workspaceID: workspaceID, surfaceID: surfaceID, timeout: options.timeout,
                client: client
            ) {
            case let .working(line):
                result["status"] = "working"
                result["evidence"] = line
            case let .blocked(reason):
                failure = reason
            case .pending:
                failure = "timeout"
            }
            if let failure {
                result["status"] = "failed"
                result["reason"] = failure
            }
        }

        if jsonOutput {
            print(jsonString(result))
        } else {
            let status = result["status"] as? String ?? "started"
            print("OK \(workspaceRef) \(status)\(failure.map { " \($0)" } ?? "")")
        }
        if let failure {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.chief.dispatch.error.notWorking",
                    defaultValue: "The agent in %@ isn't working yet (%@). Check it with: cmux read-screen --workspace %@"
                ),
                workspaceRef, failure, workspaceRef
            ))
        }
    }

    /// Watches the new terminal until the agent shows it is working, or the
    /// deadline passes. Each `surface.wait_text_change` call returns once the
    /// screen differs from the last one this loop read; the app wakes it on
    /// the terminal's output, so nothing here polls or sleeps. A screen a
    /// person must answer (trust, sign-in) is kept as the last reading but
    /// does not end the wait, since someone may answer it before the
    /// deadline.
    private func waitForChiefDispatchAgent(
        agent: ChiefDispatchAgent,
        workspaceID: String,
        surfaceID: String?,
        timeout: Int,
        client: SocketClient
    ) throws -> ChiefDispatchScreenReading {
        var params: [String: Any] = ["workspace_id": workspaceID]
        if let surfaceID { params["surface_id"] = surfaceID }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var revision: String?
        var last = ChiefDispatchScreenReading.pending
        while true {
            let remaining = max(.zero, clock.now.duration(to: deadline))
            let remainingMilliseconds = remaining.components.seconds * 1_000
                + remaining.components.attoseconds / 1_000_000_000_000_000
            var request = params
            request["timeout_ms"] = remainingMilliseconds
            if let revision { request["after_revision"] = revision }
            let payload: [String: Any]
            do {
                // Leave the app room to answer at its own deadline.
                payload = try client.sendV2(
                    method: "surface.wait_text_change",
                    params: request,
                    responseTimeout: TimeInterval(remainingMilliseconds) / 1_000 + 10
                )
            } catch {
                // A terminal that never became readable, or a closed one:
                // report what was last seen (pending reads as a timeout).
                return last
            }
            let step = ChiefDispatchWaitStep.read(payload, agent: agent)
            last = step.reading
            if step.isFinal || remainingMilliseconds == 0 { return last }
            revision = step.revision
        }
    }

    /// Writes the task and the launcher into a fresh private directory and returns their paths.
    private static func writeChiefDispatchLauncher(
        agentCommand: [String],
        prompt: String
    ) throws -> (directory: String, script: String) {
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dispatch.XXXXXXXX", isDirectory: true).path
        var buffer = Array(template.utf8CString)
        guard let created = mkdtemp(&buffer) else {
            throw chiefDispatchIOError(template)
        }
        let directory = String(cString: created)
        let promptPath = (directory as NSString).appendingPathComponent("task.txt")
        let scriptPath = (directory as NSString).appendingPathComponent("launch.sh")
        do {
            try writePrivateFile(promptPath, Data(prompt.utf8))
            let script = ChiefDispatchPlan.launcherScript(
                agentCommand: agentCommand, promptPath: promptPath, directory: directory
            )
            try writePrivateFile(scriptPath, Data(script.utf8))
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
        return (directory, scriptPath)
    }

    /// Creates `path` (it must not exist) with mode 0600 and writes `data`.
    private static func writePrivateFile(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw chiefDispatchIOError(path) }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw chiefDispatchIOError(path)
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    private static func chiefDispatchIOError(_ path: String) -> CLIError {
        CLIError(message: String(
            format: String(
                localized: "cli.chief.dispatch.error.launcherFailed",
                defaultValue: "Couldn't write the agent's launcher at %@: %@"
            ),
            path, String(cString: strerror(errno))
        ))
    }

    /// `git -C <repo> worktree add -b <branch> -- <path>`, run without a shell.
    private static func addChiefDispatchWorktree(repo: String, path: String, branch: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.chief.dispatch.error.worktreeExists",
                    defaultValue: "%@ already exists. Pick another --name or --branch."
                ),
                path
            ))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + ChiefDispatchPlan.worktreeAddArguments(repo: repo, path: path, branch: branch)
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.chief.dispatch.error.worktreeFailed",
                    defaultValue: "git worktree add failed: %@"
                ),
                "\(error)"
            ))
        }
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: String(
                format: String(
                    localized: "cli.chief.dispatch.error.worktreeFailed",
                    defaultValue: "git worktree add failed: %@"
                ),
                detail.isEmpty ? "exit \(process.terminationStatus)" : detail
            ))
        }
    }
}

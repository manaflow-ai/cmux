import CMUXAgentLaunch
import Foundation

/// `cmux session move <id> --to <ssh-destination|local>`: stop-state move of a
/// Claude session, its data and its code state, resumed in a new workspace.
extension CMUXCLI {
    func sessionCommandUsage() -> String {
        String(
            localized: "cli.session.usage",
            // One literal so the localization tooling reads the English source.
            defaultValue: "Usage: cmux session move <session-id> --to <ssh-destination|local> [options]\n\nMove a stopped Claude Code session to another machine and resume it there.\nExit the agent first: the move refuses while the session runs on either side.\n\nThe move carries:\n  - the cwd's git checkout: HEAD (on the same branch when safe) plus modified,\n    deleted and untracked non-ignored files; a worktree is added when the\n    repository exists on the destination but the path does not\n  - the transcript, its session directory, file history, and the project\n    memory directory (merged both ways, newest wins, nothing deleted)\n\nIt then opens a workspace on the destination (`cmux ssh` for a host, a local\nworkspace for `local`) that resumes the session with its recorded launcher.\nWhen the destination home is not at the same absolute path, paths under the\nhome are mapped and the project is re-slugged.\n\nOptions:\n  --to <destination>      SSH destination (user@host or ssh_config alias), or local\n  --from <destination>    Where the session is now (default: where the last move put it, else local)\n  --name <title>          Workspace title (default: the first 8 characters of the id)\n  --no-code               Do not carry the git checkout\n  --port <n>              SSH port\n  --identity <path>       SSH identity file\n  --ssh-option <opt>      Extra SSH -o option (repeatable)\n  --no-focus              Open the workspace without switching to it\n\nExamples:\n  cmux session move 0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11 --to dev@my-host\n  cmux session move 0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11 --to local"
        )
    }

    func runSessionCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard commandArgs.first == "move" else {
            if commandArgs.first == "help" || commandArgs.isEmpty {
                print(sessionCommandUsage())
                return
            }
            throw CLIError(message: String(
                format: String(localized: "cli.session.error.unknownSubcommand", defaultValue: "Unknown session subcommand: %@. Usage: cmux session move <session-id> --to <ssh-destination|local>"),
                commandArgs.first ?? ""
            ))
        }
        let options = try SessionMoveOptions(arguments: Array(commandArgs.dropFirst()))
        let sessionID = options.sessionID.lowercased()
        let home = NSHomeDirectory()
        let recordStore = SessionMoveRecordStore(home: home)
        let previous = recordStore.load(sessionID: sessionID)

        let destination = options.endpoint(for: options.to, fallback: nil)
        let source: AgentMoveEndpoint
        if let from = options.from {
            source = options.endpoint(for: from, fallback: nil)
        } else if let previous {
            source = options.endpoint(for: previous.location, fallback: previous.ssh)
        } else if destination.isLocal {
            throw CLIError(message: String(
                localized: "cli.session.move.error.unknownSource",
                defaultValue: "session move: no record of where this session was moved; pass --from <ssh-destination>"
            ))
        } else {
            source = .local
        }

        // Fail before any transfer when cmux is not running to open the workspace.
        try connectClient(socketPath: socketPath, explicitPassword: explicitPassword, launchIfNeeded: false).close()

        let mover = AgentSessionMover(
            runner: AgentMoveProcessRunner(),
            rsyncExecutable: FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") ? "/usr/bin/rsync" : "rsync",
            progress: { event in
                switch event {
                case .addingWorktree(let path):
                    cliWriteStderr(String(
                        format: String(localized: "cli.session.move.progress.addingWorktree", defaultValue: "session move: adding worktree %@ on the destination"),
                        path
                    ) + "\n")
                }
            }
        )
        let outcome: AgentMoveOutcome
        do {
            outcome = try mover.move(AgentMoveRequest(
                sessionID: sessionID,
                source: source,
                destination: destination,
                localHome: home,
                carriesCode: !options.noCode
            ))
        } catch let error as AgentMoveError {
            throw CLIError(message: sessionMoveErrorMessage(error))
        }

        recordStore.save(SessionMoveRecord(
            sessionID: sessionID,
            location: destination.isLocal ? "local" : destination.displayName,
            ssh: {
                if case .ssh(let target) = destination { return target }
                return nil
            }(),
            workingDirectory: outcome.destinationWorkingDirectory,
            movedAt: Date().timeIntervalSince1970
        ))

        let hookRecord = try? ClaudeHookSessionStore().lookup(sessionId: sessionID)
        var launchCommand = hookRecord?.launchCommand
        if !destination.isLocal {
            // cmux-owned launchers (claude-teams, ...) resume through this Mac's cmux
            // binary path, which the host does not have; resume the plain agent argv
            // there. A user-declared external launcher is kept: it names a command
            // the user runs on every machine.
            launchCommand?.launcher = nil
        }
        let localWorkingDirectory = source.isLocal ? outcome.sourceWorkingDirectory : outcome.destinationWorkingDirectory
        let resumeCommand = agentSurfaceResumeCommand(
            kind: "claude",
            sessionId: sessionID,
            launchCommand: launchCommand,
            workingDirectory: outcome.destinationWorkingDirectory,
            environment: nil,
            observedPermissionMode: hookRecord?.lastPermissionMode,
            launcherConfigurationDirectory: localWorkingDirectory
        ) ?? agentSurfaceResumeCommand(
            kind: "claude",
            sessionId: sessionID,
            launchCommand: nil,
            workingDirectory: outcome.destinationWorkingDirectory,
            environment: nil
        ) ?? "claude --resume \(sessionID)"

        let client = try connectClient(socketPath: socketPath, explicitPassword: explicitPassword, launchIfNeeded: false)
        defer { client.close() }
        // The session left this Mac: its old surface must not auto-resume a second writer.
        if source.isLocal, let hookRecord {
            _ = clearAgentSurfaceResumeBinding(
                client: client,
                workspaceId: hookRecord.workspaceId,
                surfaceId: hookRecord.surfaceId,
                sessionId: sessionID
            )
        }

        let name = options.name ?? String(sessionID.prefix(8))
        switch destination {
        case .ssh(let target):
            var sshArgs = [target.destination, "--name", name, "--command", resumeCommand]
            if let port = target.port { sshArgs += ["--port", port] }
            if let identity = target.identityFile { sshArgs += ["--identity", identity] }
            for option in target.options { sshArgs += ["--ssh-option", option] }
            if options.noFocus { sshArgs.append("--no-focus") }
            try runSSH(
                commandArgs: sshArgs,
                client: client,
                jsonOutput: false,
                idFormat: idFormat,
                windowOverride: windowOverride,
                defaultTerminalTransport: .ssh
            )
        case .local:
            try runWorkspaceCreateCommand(
                commandName: "new-workspace",
                commandArgs: [
                    "--name", name,
                    "--cwd", outcome.destinationWorkingDirectory,
                    "--command", resumeCommand,
                    "--focus", options.noFocus ? "false" : "true",
                ],
                client: client,
                jsonOutput: false,
                idFormat: idFormat,
                windowOverride: windowOverride,
                honorJSONOutput: false
            )
        }

        for line in sessionMoveSummary(outcome: outcome, source: source, destination: destination) {
            print(line)
        }
    }

    private func sessionMoveSummary(outcome: AgentMoveOutcome, source: AgentMoveEndpoint, destination: AgentMoveEndpoint) -> [String] {
        var lines: [String] = []
        switch outcome.code {
        case .skipped:
            break
        case .notGitCheckout(let path):
            lines.append(String(
                format: String(localized: "cli.session.move.output.notGit", defaultValue: "Code: %@ is not a git checkout; no files were moved."),
                path
            ))
        case .synced(let checkout, let head, let branch, let snapshot, _):
            lines.append(String(
                format: String(localized: "cli.session.move.output.code", defaultValue: "Code: %@ at %@ (%@) with working tree snapshot %@."),
                checkout,
                String(head.prefix(10)),
                branch ?? String(localized: "cli.session.move.output.detached", defaultValue: "detached"),
                String(snapshot.prefix(10))
            ))
        }
        if outcome.pathMap.rewritesPaths {
            lines.append(String(
                format: String(localized: "cli.session.move.output.pathsRewritten", defaultValue: "Paths were rewritten: %@ -> %@. Absolute paths inside the transcript still name the old home."),
                outcome.pathMap.sourceHome,
                outcome.pathMap.destinationHome
            ))
        }
        lines.append(String(
            format: String(localized: "cli.session.move.output.moved", defaultValue: "Moved session %@ to %@ (cwd %@)."),
            outcome.sessionID,
            destination.displayName,
            outcome.destinationWorkingDirectory
        ))
        lines.append(String(
            format: String(localized: "cli.session.move.output.sourceKept", defaultValue: "The copy on %@ stays; do not resume it there too."),
            source.displayName
        ))
        return lines
    }

    private func sessionMoveErrorMessage(_ error: AgentMoveError) -> String {
        switch error {
        case .invalidSessionID(let value):
            return String(format: String(localized: "cli.session.move.error.invalidSessionID", defaultValue: "session move: '%@' is not a session id"), value)
        case .sameEndpoint:
            return String(localized: "cli.session.move.error.sameEndpoint", defaultValue: "session move: the session is already there")
        case .unsupportedRoute:
            return String(localized: "cli.session.move.error.unsupportedRoute", defaultValue: "session move: moves go between this Mac and one host; move the session back with --to local first")
        case .unsupportedSSHTarget(let destination):
            return String(format: String(localized: "cli.session.move.error.unsupportedSSHTarget", defaultValue: "session move: unsupported SSH destination or option for '%@' (use user@host or an ssh_config alias, without whitespace)"), destination)
        case .unreachable(let host, let detail):
            return String(format: String(localized: "cli.session.move.error.unreachable", defaultValue: "session move: cannot reach %@: %@"), host, detail)
        case .liveOnSource(let host):
            return String(format: String(localized: "cli.session.move.error.liveOnSource", defaultValue: "session move: the session is still running on %@; exit the agent at the end of its turn, then move it"), host)
        case .liveOnDestination(let host):
            return String(format: String(localized: "cli.session.move.error.liveOnDestination", defaultValue: "session move: the session is already running on %@"), host)
        case .transcriptNotFound(let host):
            return String(format: String(localized: "cli.session.move.error.transcriptNotFound", defaultValue: "session move: no Claude transcript for this session on %@"), host)
        case .workingDirectoryUnknown:
            return String(localized: "cli.session.move.error.workingDirectoryUnknown", defaultValue: "session move: the transcript does not record the session's working directory")
        case .unsupportedPath(let path):
            return String(format: String(localized: "cli.session.move.error.unsupportedPath", defaultValue: "session move: paths with whitespace are not supported: %@"), path)
        case .destinationRepositoryMissing(let checkout, let repository):
            return String(format: String(localized: "cli.session.move.error.repositoryMissing", defaultValue: "session move: no checkout at %@ and no repository at %@ on the destination; clone it there first"), checkout, repository)
        case .worktreeAddFailed(let path, let detail):
            return String(format: String(localized: "cli.session.move.error.worktreeAddFailed", defaultValue: "session move: could not add a worktree at %@: %@"), path, detail)
        case .destinationCheckoutDirty(let path):
            return String(format: String(localized: "cli.session.move.error.checkoutDirty", defaultValue: "session move: %@ on the destination has changes that did not come from this session; commit or stash them there first"), path)
        case .destinationBranchDiverged(let branch):
            return String(format: String(localized: "cli.session.move.error.branchDiverged", defaultValue: "session move: branch %@ on the destination has commits the session's HEAD does not contain"), branch)
        case .gitFailed(let step, let detail):
            return String(format: String(localized: "cli.session.move.error.gitFailed", defaultValue: "session move: git %@ failed: %@"), step, detail)
        case .destinationWorkingDirectoryMissing(let path):
            return String(format: String(localized: "cli.session.move.error.cwdMissing", defaultValue: "session move: %@ does not exist on the destination"), path)
        case .destinationTranscriptNewer:
            return String(localized: "cli.session.move.error.transcriptNewer", defaultValue: "session move: the destination transcript is newer; the session continued there, so move it the other way")
        case .transcriptsDiverged:
            return String(localized: "cli.session.move.error.transcriptsDiverged", defaultValue: "session move: the transcripts diverged (the destination copy is not a prefix of the source); resolve by hand")
        case .copyFailed(let path, let detail):
            return String(format: String(localized: "cli.session.move.error.copyFailed", defaultValue: "session move: copying %@ failed: %@"), path, detail)
        }
    }
}

/// Parsed `cmux session move` arguments.
struct SessionMoveOptions {
    var sessionID = ""
    var to = ""
    var from: String?
    var name: String?
    var noCode = false
    var noFocus = false
    var port: String?
    var identity: String?
    var sshOptions: [String] = []

    init(arguments: [String]) throws {
        var positional: [String] = []
        var index = 0
        func value(_ flag: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                throw CLIError(message: String(
                    format: String(localized: "cli.session.move.error.flagRequiresValue", defaultValue: "session move: %@ requires a value"),
                    flag
                ))
            }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--to": to = try value(argument)
            case "--from": from = try value(argument)
            case "--name": name = try value(argument)
            case "--port": port = try value(argument)
            case "--identity": identity = try value(argument)
            case "--ssh-option": sshOptions.append(try value(argument))
            case "--no-code": noCode = true
            case "--no-focus": noFocus = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError(message: String(
                        format: String(localized: "cli.session.move.error.unknownFlag", defaultValue: "session move: unknown flag '%@'"),
                        argument
                    ))
                }
                positional.append(argument)
            }
            index += 1
        }
        guard positional.count == 1, !to.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.session.move.error.usage",
                defaultValue: "Usage: cmux session move <session-id> --to <ssh-destination|local>"
            ))
        }
        sessionID = positional[0]
    }

    /// `local` or an SSH destination; SSH flags from the command line apply to it.
    func endpoint(for name: String, fallback: AgentMoveSSHTarget?) -> AgentMoveEndpoint {
        if name == "local" { return .local }
        // The recorded target keeps the SSH flags of the move that put the session there.
        if let fallback, fallback.destination == name, port == nil, identity == nil, sshOptions.isEmpty {
            return .ssh(fallback)
        }
        return .ssh(AgentMoveSSHTarget(destination: name, port: port, identityFile: identity, options: sshOptions))
    }
}

/// Where the last move put a session, kept at `~/.cmuxterm/agent-moves/<id>.json`
/// so `--to local` knows which host to bring it back from.
struct SessionMoveRecord: Codable {
    var sessionID: String
    var location: String
    var ssh: AgentMoveSSHTarget?
    var workingDirectory: String
    var movedAt: TimeInterval
}

struct SessionMoveRecordStore {
    let directory: URL

    init(home: String) {
        directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cmuxterm/agent-moves", isDirectory: true)
    }

    func load(sessionID: String) -> SessionMoveRecord? {
        guard let data = try? Data(contentsOf: url(sessionID)) else { return nil }
        return try? JSONDecoder().decode(SessionMoveRecord.self, from: data)
    }

    func save(_ record: SessionMoveRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(record.sessionID), options: .atomic)
    }

    private func url(_ sessionID: String) -> URL {
        directory.appendingPathComponent("\(sessionID).json", isDirectory: false)
    }
}

/// Runs move commands with `Process`, capturing output. Standard input is
/// `/dev/null`, so `ssh` never waits on the terminal, unless the invocation
/// carries `standardInput` (a remote script for `sh -s`), which goes to a pipe.
struct AgentMoveProcessRunner: AgentMoveCommandRunning {
    func run(_ invocation: AgentMoveInvocation) throws -> AgentMoveCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = invocation.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        let input = invocation.standardInput.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try cliRunProcess(process)
        if let input, let text = invocation.standardInput {
            // Scripts are small; ssh reads them before the remote side produces output.
            input.fileHandleForWriting.write(Data(text.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Drain stderr concurrently so neither pipe fills and blocks the child.
        let errorBox = AgentMoveDataBox()
        let errorDrained = DispatchSemaphore(value: 0)
        let errorHandle = error.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.data = errorHandle.readDataToEndOfFile()
            errorDrained.signal()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        process.waitUntilExit()
        return AgentMoveCommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorBox.data, as: UTF8.self)
        )
    }
}

/// Written once by the stderr reader before the semaphore signal, read after the wait.
private final class AgentMoveDataBox: @unchecked Sendable {
    var data = Data()
}

import Foundation

/// Moves a stopped Claude session, its data and its code state between this
/// machine and an SSH host. The caller then resumes it on the destination.
///
/// Order matters: liveness and the transcript prefix are checked before the
/// destination checkout changes, and code is carried before session data, so a
/// refusal leaves the destination's session files untouched.
public struct AgentSessionMover {
    private let runner: any AgentMoveCommandRunning
    private let rsyncExecutable: String
    private let progress: (AgentMoveProgress) -> Void
    private let scripts = AgentMoveScripts()

    /// Creates a mover.
    ///
    /// - Parameters:
    ///   - runner: Runs `sh`, `ssh`, `git` and `rsync`.
    ///   - rsyncExecutable: The `rsync` to run. The CLI pins `/usr/bin/rsync` on macOS.
    ///   - progress: Receives intermediate progress.
    public init(
        runner: any AgentMoveCommandRunning,
        rsyncExecutable: String = "rsync",
        progress: @escaping (AgentMoveProgress) -> Void = { _ in }
    ) {
        self.runner = runner
        self.rsyncExecutable = rsyncExecutable
        self.progress = progress
    }

    /// Whether `value` looks like a Claude session id.
    public static func isSessionID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Runs the move. See the type documentation for the order of steps.
    public func move(_ request: AgentMoveRequest) throws -> AgentMoveOutcome {
        let id = request.sessionID.lowercased()
        guard Self.isSessionID(id) else { throw AgentMoveError.invalidSessionID(request.sessionID) }
        guard request.source != request.destination else { throw AgentMoveError.sameEndpoint }
        let remote: AgentMoveSSHTarget
        switch (request.source, request.destination) {
        case (.local, .ssh(let target)), (.ssh(let target), .local):
            remote = target
        default:
            throw AgentMoveError.unsupportedRoute
        }
        guard remote.isTransportSafe else { throw AgentMoveError.unsupportedSSHTarget(remote.destination) }

        let probe = try shell(.ssh(remote), scripts.probeHome(localHome: request.localHome))
        guard probe.succeeded, let probedHome = marker("AM_HOME", in: probe.standardOutput), !probedHome.isEmpty else {
            throw AgentMoveError.unreachable(host: remote.destination, detail: probe.failureDetail)
        }
        // A remote home that is the local home directory (same path, or a bind
        // mount at the local path) is addressed by the local path on both sides.
        let sharesHome = marker("AM_SAME", in: probe.standardOutput) == "yes"
        let remoteHome = sharesHome ? request.localHome : probedHome
        let sourceHome = request.source.isLocal ? request.localHome : remoteHome
        let destinationHome = request.destination.isLocal ? request.localHome : remoteHome
        let pathMap = AgentMovePathMap(sourceHome: sourceHome, destinationHome: destinationHome, sharesHomePath: sharesHome)
        let sourceClaude = sourceHome + "/.claude"
        let destinationClaude = destinationHome + "/.claude"

        if try isLive(on: request.source, claudeDirectory: sourceClaude, sessionID: id) {
            throw AgentMoveError.liveOnSource(host: request.source.displayName)
        }
        if try isLive(on: request.destination, claudeDirectory: destinationClaude, sessionID: id) {
            throw AgentMoveError.liveOnDestination(host: request.destination.displayName)
        }

        let transcript = try shell(request.source, scripts.findTranscript(claudeDirectory: sourceClaude, sessionID: id)).trimmedOutput
        guard !transcript.isEmpty else { throw AgentMoveError.transcriptNotFound(host: request.source.displayName) }
        let cwdLine = try shell(request.source, scripts.transcriptWorkingDirectory(transcript: transcript)).trimmedOutput
        guard let recordedCwd = Self.workingDirectory(fromCwdField: cwdLine) else {
            throw AgentMoveError.workingDirectoryUnknown
        }
        // A transcript carried here by an earlier rewriting move still names the
        // other machine's home until the session runs a turn here; map it back.
        let sourceCwd = AgentMovePathMap(
            sourceHome: pathMap.destinationHome,
            destinationHome: pathMap.sourceHome,
            sharesHomePath: sharesHome
        ).destinationPath(for: recordedCwd)
        try requirePlain(sourceCwd)
        try requirePlain(transcript)
        let destinationCwd = pathMap.destinationPath(for: sourceCwd)
        try requirePlain(destinationCwd)

        let sourceProjectDirectory = (transcript as NSString).deletingLastPathComponent
        let destinationSlug = sharesHome
            ? (sourceProjectDirectory as NSString).lastPathComponent
            : ClaudeProjectSlug().slug(forWorkingDirectory: destinationCwd)
        let destinationProjectDirectory = destinationClaude + "/projects/" + destinationSlug
        // Decided before code moves: a session that continued on the destination
        // must not have its checkout rewritten to the older source state.
        try requireDestinationTranscriptIsPrefix(
            source: request.source,
            sourceTranscript: sourceProjectDirectory + "/" + id + ".jsonl",
            destination: request.destination,
            destinationTranscript: destinationProjectDirectory + "/" + id + ".jsonl"
        )

        let code: AgentMoveCodeOutcome
        if request.carriesCode {
            code = try AgentMoveCodeSync(mover: self, sessionID: id, pathMap: pathMap)
                .carry(from: request.source, workingDirectory: sourceCwd, to: request.destination)
        } else {
            code = .skipped
        }
        guard try shell(request.destination, scripts.isDirectory(destinationCwd)).succeeded else {
            throw AgentMoveError.destinationWorkingDirectoryMissing(destinationCwd)
        }

        try carrySessionData(
            sessionID: id,
            source: request.source,
            sourceClaude: sourceClaude,
            sourceProjectDirectory: sourceProjectDirectory,
            destination: request.destination,
            destinationClaude: destinationClaude,
            destinationProjectDirectory: destinationProjectDirectory
        )

        return AgentMoveOutcome(
            sessionID: id,
            sourceWorkingDirectory: sourceCwd,
            destinationWorkingDirectory: destinationCwd,
            destinationTranscriptPath: destinationProjectDirectory + "/" + id + ".jsonl",
            pathMap: pathMap,
            code: code
        )
    }

    // MARK: - Session data

    private func carrySessionData(
        sessionID id: String,
        source: AgentMoveEndpoint,
        sourceClaude: String,
        sourceProjectDirectory: String,
        destination: AgentMoveEndpoint,
        destinationClaude: String,
        destinationProjectDirectory: String
    ) throws {
        let sourceTranscript = sourceProjectDirectory + "/" + id + ".jsonl"
        let history = "/file-history/"
        let made = try shell(destination, scripts.makeDirectories([destinationProjectDirectory, destinationClaude + "/file-history"]))
        guard made.succeeded else { throw AgentMoveError.copyFailed(path: destinationProjectDirectory, detail: made.failureDetail) }

        try copy(from: source, sourceTranscript, to: destination, destinationProjectDirectory + "/")
        let sidecar = sourceProjectDirectory + "/" + id
        if try shell(source, scripts.isDirectory(sidecar)).succeeded {
            try copy(from: source, sidecar, to: destination, destinationProjectDirectory + "/")
        }
        let sourceHistory = sourceClaude + history + id
        if try shell(source, scripts.isDirectory(sourceHistory)).succeeded {
            try copy(from: source, sourceHistory, to: destination, destinationClaude + history)
        }
        // Project memory: merged both ways, newest wins, nothing deleted.
        let sourceMemory = sourceProjectDirectory + "/memory/"
        let destinationMemory = destinationProjectDirectory + "/memory/"
        if try shell(source, scripts.isDirectory(sourceMemory)).succeeded {
            try copy(from: source, sourceMemory, to: destination, destinationMemory, updateOnly: true)
        }
        if try shell(destination, scripts.isDirectory(destinationMemory)).succeeded {
            try copy(from: destination, destinationMemory, to: source, sourceMemory, updateOnly: true)
        }
    }

    /// Transcripts only grow, so a destination copy must be a byte prefix of the source.
    private func requireDestinationTranscriptIsPrefix(
        source: AgentMoveEndpoint,
        sourceTranscript: String,
        destination: AgentMoveEndpoint,
        destinationTranscript: String
    ) throws {
        guard let destinationSize = Int(try shell(destination, scripts.fileSize(destinationTranscript)).trimmedOutput),
              destinationSize > 0 else { return }
        let sourceSize = Int(try shell(source, scripts.fileSize(sourceTranscript)).trimmedOutput) ?? 0
        guard destinationSize <= sourceSize else { throw AgentMoveError.destinationTranscriptNewer }
        let sourceSum = try shell(source, scripts.prefixChecksum(sourceTranscript, bytes: destinationSize))
        let destinationSum = try shell(destination, scripts.checksum(destinationTranscript))
        guard sourceSum.succeeded, destinationSum.succeeded, sourceSum.trimmedOutput == destinationSum.trimmedOutput else {
            throw AgentMoveError.transcriptsDiverged
        }
    }

    private func copy(
        from source: AgentMoveEndpoint,
        _ sourcePath: String,
        to destination: AgentMoveEndpoint,
        _ destinationPath: String,
        updateOnly: Bool = false
    ) throws {
        var arguments = [rsyncExecutable, "-a", "--partial"]
        if updateOnly { arguments.append("-u") }
        for case .ssh(let target) in [source, destination] {
            arguments += ["-e", target.sshCommandLine]
        }
        arguments += [source.transferPath(sourcePath), destination.transferPath(destinationPath)]
        let result = try runner.run(AgentMoveInvocation(arguments: arguments))
        guard result.succeeded else { throw AgentMoveError.copyFailed(path: sourcePath, detail: result.failureDetail) }
    }

    // MARK: - Helpers shared with code sync

    func shell(_ endpoint: AgentMoveEndpoint, _ script: String) throws -> AgentMoveCommandResult {
        let result = try runner.run(endpoint.shellInvocation(script))
        if result.status == 255, case .ssh(let target) = endpoint {
            throw AgentMoveError.unreachable(host: target.destination, detail: result.failureDetail)
        }
        return result
    }

    func run(_ invocation: AgentMoveInvocation) throws -> AgentMoveCommandResult {
        try runner.run(invocation)
    }

    func report(_ event: AgentMoveProgress) {
        progress(event)
    }

    func requirePlain(_ path: String) throws {
        if path.contains(where: { $0.isWhitespace }) { throw AgentMoveError.unsupportedPath(path) }
    }

    func marker(_ name: String, in output: String) -> String? {
        let prefix = name + "="
        return output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func isLive(on endpoint: AgentMoveEndpoint, claudeDirectory: String, sessionID: String) throws -> Bool {
        let result = try shell(endpoint, scripts.liveness(claudeDirectory: claudeDirectory, sessionID: sessionID))
        return result.standardOutput
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "AM_LIVE" }
    }

    /// Extracts the path from a `"cwd":"<path>"` transcript field, undoing JSON string escapes.
    static func workingDirectory(fromCwdField field: String) -> String? {
        guard let data = "{\(field)}".data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/") else { return nil }
        return cwd
    }
}

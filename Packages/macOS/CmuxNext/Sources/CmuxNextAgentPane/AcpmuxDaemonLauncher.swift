import Darwin
import Foundation
import os
import CmuxNextCompat
import struct CmuxNextDaemon.POSIXErrorText
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Starts a detached acpmux daemon and returns its WebSocket endpoint from
/// the `--ready-fd` line, so a fresh daemon needs no status round trip.
///
/// The daemon runs as a background job of a throwaway `/bin/sh` with job
/// control on (`set -m`), so it gets its own process group, is adopted by
/// launchd when the shell exits, and outlives the app (its sessions are
/// durable state). The launcher reaps the shell. Its fd 3 is our pipe; stdout and stderr go to
/// `<home>/daemon.log`.
nonisolated enum AcpmuxDaemonLauncher {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    nonisolated enum Failure: Error, Equatable {
        case spawnFailed(String)
        /// A Team-signed app refuses an executable that is not validly signed by its team.
        case untrustedExecutable(String)
        /// The daemon exited before it was ready; its log says why.
        case exited(logPath: String)
        /// Ready, but without a WebSocket listener (the port was taken).
        case noWebSocket(logPath: String)
    }

    static let script = #"set -m; "$@" 3>&1 1>>"$ACPMUX_LAUNCH_LOG" 2>&1 </dev/null &"#
    /// The daemon reads its person key (``AcpmuxPersonKey``) from this descriptor and
    /// closes it before it starts any agent; the key never goes into argv or the environment.
    static let personKeyDescriptor: Int32 = 4

    /// Process basics that are safe for a Team-signed helper to inherit. Its
    /// login-environment loader supplies user tool and credential variables
    /// after start; the app process's unrelated capabilities never cross the
    /// unverified launch boundary.
    private static let signedInheritedKeys: Set<String> = [
        "HOME", "LANG", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING",
    ]

    static func arguments(for environment: AcpmuxEnvironment) -> [String] {
        ["-c", script, "acpmux-launch", environment.executable.path, "daemon", "run", "--ready-fd", "3"]
            + (environment.passesPersonKeyAtSpawn ? ["--person-key-fd", String(personKeyDescriptor)] : [])
            + environment.daemonArguments
    }

    /// The daemon's environment: this app's, without any inherited Computer
    /// Use secret, plus `childEnvironment`, non-secret Computer Use v2 state,
    /// the session offer tools while suggested tasks are on
    /// (``AcpmuxEnvironment/offersSessionTools``), the agent message runaway guard
    /// off when ``AcpmuxEnvironment/agentPairGuard`` is off (else its cap), the app's daemon
    /// features (``AcpmuxEnvironment/daemonFeatures``) and the launch knobs.
    static func spawnEnvironment(_ environment: AcpmuxEnvironment, inherited: [String: String]) -> [String: String] {
        let computerUse = Set(AcpmuxEnvironment.computerUseKeys + [AcpmuxEnvironment.computerUseHostKey])
        let safeInherited = inherited.filter { key, _ in
            !computerUse.contains(key)
                && (environment.passesPersonKeyAtSpawn
                    || signedInheritedKeys.contains(key)
                    || key.hasPrefix("LC_"))
        }
        var variables = safeInherited.merging(environment.childEnvironment) { $1 }
        for (key, value) in environment.computerUse where !value.isEmpty {
            let developmentCredential = environment.passesPersonKeyAtSpawn
                && AcpmuxEnvironment.computerUseKeys.contains(key)
            if !computerUse.contains(key) || developmentCredential { variables[key] = value }
        }
        if environment.offersSessionTools { variables[AcpmuxEnvironment.offerToolsKey] = "1" }
        if environment.agentPairGuard {
            variables[AcpmuxEnvironment.agentPairCapKey] = String(max(0, environment.agentPairCap))
            variables[AcpmuxEnvironment.agentPairWindowKey] = String(max(0, environment.agentPairWindowSeconds))
        } else {
            variables[AcpmuxEnvironment.agentPairGuardKey] = "0"
        }
        variables.merge(environment.daemonFeatures) { $1 }
        variables["ACPMUX_LAUNCH_LOG"] = environment.logPath
        variables["ACPMUX_LOGIN_ENV"] = "1"
        // The owning app: the leftover daemon idle exit keeps the daemon while it runs.
        variables["ACPMUX_OWNER_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        return variables
    }

    /// Starts the daemon and waits for its ready line. `deadline` is a stall time: the wait ends
    /// with an error only after that long with no write to the daemon's log, or at its exit. The launch
    /// shell starts on `launcher` (the host's, user-blocking: the agent pane waits for its daemon).
    ///
    /// Its home's creation blocks the caller's thread, so it runs on the caller's executor:
    /// ``AcpmuxHost``'s own queue, never the main thread or the cooperative pool.
    static func launch(_ environment: AcpmuxEnvironment, deadline: Duration = .seconds(20),
                       launcher: ChildProcessLauncher) async throws -> AcpmuxWebEndpoint {
        try await launch(environment, deadline: deadline, launcher: launcher, onSpawn: { _ in })
    }

    /// `onSpawn` gets the launch shell's pid (tests check that it was reaped).
    static func launch(_ environment: AcpmuxEnvironment, deadline: Duration, launcher: ChildProcessLauncher,
                       onSpawn: @Sendable (pid_t) -> Void) async throws -> AcpmuxWebEndpoint {
        // cmux NEXT's one-time adoption of its old acpmux home ends before any daemon starts (cx-is1kf.9).
        await AcpmuxEnvironment.adoptBuildHomes()
        guard AcpmuxServerPeer.executableSignedByAppTeam(environment.executable, team: SigningTeamInstall.process.team) else {
            throw Failure.untrustedExecutable(environment.executable.path)
        }
        logger.info("acpmux launch requested executable=\(environment.executable.path, privacy: .public) home=\(environment.home.path, privacy: .public) socket=\(environment.socketPath, privacy: .public) args=\(environment.daemonArguments.joined(separator: " "), privacy: .public)")
        try FileManager.checked.createDirectory(at: environment.home, withIntermediateDirectories: true)
        let variables = spawnEnvironment(environment, inherited: ProcessInfo.processInfo.environment)
        logger.info("acpmux launch environment home=\(variables["ACPMUX_HOME", default: ""], privacy: .public) socket=\(variables["ACPMUX_SOCKET", default: ""], privacy: .public) pathPresent=\(variables["PATH"] != nil, privacy: .public)")
        var outputPipe: [Int32] = [-1, -1]
        // SAFETY: pipe writes its two descriptors into the array's own storage (two Int32), lent for the call.
        guard unsafe Darwin.pipe(&outputPipe) == 0 else {
            throw Failure.spawnFailed(POSIXErrorText(errno).description)
        }
        defer {
            if outputPipe[0] >= 0 { Darwin.close(outputPipe[0]) }
            if outputPipe[1] >= 0 { Darwin.close(outputPipe[1]) }
        }
        // Only unsigned DEV needs a spawn key. A signed daemon gets no key or
        // legacy Computer Use token until a checked socket enrolls it below.
        var keyPipe: [Int32] = [-1, -1]
        if environment.passesPersonKeyAtSpawn {
            // SAFETY: pipe writes its two descriptors into the array's own storage (two Int32), lent for the call.
            guard unsafe Darwin.pipe(&keyPipe) == 0 else {
                throw Failure.spawnFailed(POSIXErrorText(errno).description)
            }
            // Close-on-exec at once: a child another part of this app spawns meanwhile never
            // inherits either end. The spawn's dup2 to the daemon's descriptor clears it there.
            guard fcntl(keyPipe[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(keyPipe[1], F_SETFD, FD_CLOEXEC) == 0 else {
                Darwin.close(keyPipe[0])
                Darwin.close(keyPipe[1])
                throw Failure.spawnFailed(POSIXErrorText(errno).description)
            }
            // A new key for this unsigned daemon (one key per daemon instance, cx-fcaq).
            let keyLine = Array((AcpmuxPersonKey.spawnKey(for: environment.socketPath) + "\n").utf8)
            // SAFETY: write reads keyLine.count bytes from the array's own storage, lent for the call.
            let written = unsafe Darwin.write(keyPipe[1], keyLine, keyLine.count)
            guard written == keyLine.count else { throw Failure.spawnFailed("unable to pass the person key") }
            Darwin.close(keyPipe[1])
            keyPipe[1] = -1
        }
        defer {
            if keyPipe[0] >= 0 { Darwin.close(keyPipe[0]) }
            if keyPipe[1] >= 0 { Darwin.close(keyPipe[1]) }
        }
        // posix_spawn follows exec(2)'s argv contract. Foundation.Process accepts
        // arguments without argv[0], but the shell requires its executable name
        // in argv[0] before `-c` and the script.
        let spawnArguments = ["/bin/sh"] + arguments(for: environment)
        let spawnVariables = variables.map { "\($0.key)=\($0.value)" }
        let descriptors = SpawnDescriptors(outputRead: outputPipe[0], outputWrite: outputPipe[1],
                                           keyRead: environment.passesPersonKeyAtSpawn ? keyPipe[0] : nil)
        // On the launcher, never on the caller's queue.
        let (spawnStatus, processIdentifier) = try await launcher.run { () throws -> (status: Int32, pid: pid_t) in
            try Self.spawnShell(arguments: spawnArguments, variables: spawnVariables, descriptors: descriptors,
                                priority: launcher.priority)
        }
        // The shell holds its own copy of the DEV key's read end now (or the spawn failed).
        if keyPipe[0] >= 0 {
            Darwin.close(keyPipe[0])
            keyPipe[0] = -1
        }
        guard spawnStatus == 0 else {
            let why = POSIXErrorText(spawnStatus).description
            logger.error("acpmux spawn failed status=\(spawnStatus, privacy: .public) errno=\(why, privacy: .public) executable=/bin/sh")
            throw Failure.spawnFailed(why)
        }
        logger.info("acpmux spawn succeeded executable=/bin/sh")
        onSpawn(processIdentifier)
        // The shell exits as soon as it has put the daemon in the background (the daemon
        // goes to launchd). Reap it on every path out, or each launch leaves a zombie child
        // in this process (cx-xqng).
        let ready: Result<AcpmuxWebEndpoint, any Error>
        do {
            ready = .success(try await readReadyLine(&outputPipe, environment: environment, deadline: deadline))
        } catch {
            ready = .failure(error)
        }
        await Self.reap(processIdentifier)
        return try ready.get()
    }

    /// The pipe ends the launch shell gets: `outputRead` closes in it, `outputWrite` is its stdout, and
    /// `keyRead` (an unsigned DEV daemon only) is its ``personKeyDescriptor``.
    private struct SpawnDescriptors: Sendable {
        let outputRead: Int32
        let outputWrite: Int32
        let keyRead: Int32?
    }

    /// Spawns `/bin/sh` with `arguments` (argv[0] first) and `variables` (`KEY=value`) at `priority`: stdin and
    /// stderr /dev/null, its own session, and no descriptor of the app but `descriptors`. Blocking:
    /// ``launch(_:deadline:launcher:onSpawn:)`` runs it on a ``ChildProcessLauncher``.
    /// - Returns: `posix_spawn`'s status and the shell's pid.
    private static func spawnShell(arguments: [String], variables: [String], descriptors: SpawnDescriptors,
                                   priority: MayBlockPriority) throws -> (status: Int32, pid: pid_t) {
        // SAFETY (every posix_spawn_* call below): each takes the address of `actions` or `attributes`, locals
        // initialized here and destroyed once by the defer, and copies the C strings it is lent (the NUL-terminated
        // copies made for the call) before it returns.
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard unsafe posix_spawn_file_actions_init(&actions) == 0,
              unsafe posix_spawnattr_init(&attributes) == 0 else {
            throw Failure.spawnFailed("unable to initialize acpmux spawn")
        }
        defer {
            unsafe posix_spawn_file_actions_destroy(&actions)
            unsafe posix_spawnattr_destroy(&attributes)
        }
        // The read end closes first: in a process with few descriptors open it can be the
        // person key's descriptor, and closing it after the dup2 dropped the key (the daemon
        // then closed its own I/O driver's descriptor in its place and panicked).
        guard unsafe posix_spawn_file_actions_addclose(&actions, descriptors.outputRead) == 0,
              unsafe posix_spawn_file_actions_adddup2(&actions, descriptors.outputWrite, STDOUT_FILENO) == 0,
              unsafe descriptors.keyRead.map({ unsafe posix_spawn_file_actions_adddup2(&actions, $0, personKeyDescriptor) == 0 }) ?? true,
              unsafe posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              unsafe posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw Failure.spawnFailed("unable to configure acpmux spawn")
        }
        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
        guard unsafe posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
            throw Failure.spawnFailed("unable to configure acpmux descriptor policy")
        }
        var processIdentifier: pid_t = 0
        // SAFETY: argv and envp are NULL-terminated lists that withCStringList lends for its closure; posix_spawn
        // copies them, writes the child's pid into `processIdentifier`, a local, and reads `actions` and
        // `attributes` (above).
        let status = unsafe withCStringList(arguments) { argv in
            unsafe withCStringList(variables) { envp in
                unsafe blockingPosixSpawn(&processIdentifier, "/bin/sh", &actions, &attributes, argv, envp, priority: priority)
            }
        }
        guard let status = status.flatMap({ $0 }) else {
            throw Failure.spawnFailed("unable to allocate acpmux spawn arguments")
        }
        return (status, processIdentifier)
    }

    private static func readReadyLine(_ outputPipe: inout [Int32], environment: AcpmuxEnvironment,
                                      deadline: Duration) async throws -> AcpmuxWebEndpoint {
        // Only the spawned shell and daemon may hold the write end. The CLOEXEC
        // default above closes every inherited descriptor; the shell creates
        // descriptor 3 explicitly for the ready line.
        Darwin.close(outputPipe[1])
        outputPipe[1] = -1
        let reader = AgentPaneLineReader(handle: FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: false))
        // The ready line, or the daemon's exit (end of file), is the signal. `deadline` bounds only
        // a stall: the wait goes on while the daemon still writes its log (AcpmuxLogProgress).
        let progress = AcpmuxLogProgress(logPath: environment.logPath)
        let line: String
        do {
            line = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await reader.firstLine() }
                group.addTask {
                    try await progress.stalled(for: deadline)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let line = first else {
                    throw AgentPaneDeadlineExceeded(label: "acpmux start (no log write for \(deadline))")
                }
                return line
            }
        } catch AgentPaneLineReader.Failure.endOfFile {
            throw Failure.exited(logPath: environment.logPath)
        }
        guard let ready = AcpmuxReadyLine.parse(line) else { throw Failure.exited(logPath: environment.logPath) }
        guard let webURL = ready.webUrl, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw Failure.noWebSocket(logPath: environment.logPath)
        }
        return endpoint
    }

    /// Collects the launch shell's exit status without blocking a thread while it runs.
    /// The shell exits as soon as it has put the daemon in the background, so the wait
    /// has no bound: a shell left unreaped stays a zombie child of this process for its
    /// whole life (cx-xqng). The earlier version leaked it two ways: a non-blocking
    /// `waitpid` right after the exit event, which the kernel can post before the
    /// status is collectable, and a 5 s bound a busy machine can pass (hosted runs
    /// 37835676794, 37845131094, 37847351675: three launches, three zombies).
    /// ``ChildExitWatch`` reaps it: a blocking `waitpid` after the exit event, and a check once the source is
    /// armed for a shell that exited before. A shell that never exited would hold the launch; the script only
    /// backgrounds the daemon, in its own session (no terminal can stop it), so it cannot.
    private static func reap(_ pid: pid_t) async {
        // A watch dropped without its exit event ends the wait (abandoned): the launch goes on.
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            ChildExitWatch(pid: pid, queue: DispatchQueue(label: "cmux.next.agent-pane.acpmux-launch-reap.\(pid)", qos: .userInitiated))
                .start { _ in continuation.resume(returning: ()) }
        }
    }
}

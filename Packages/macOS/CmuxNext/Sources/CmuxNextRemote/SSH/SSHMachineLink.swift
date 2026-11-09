import CmuxNextCloud
import CmuxNextCompat
import CryptoKit
public import Foundation
import os

/// Per-installation SSH link state: the cmux-tui client identity and
/// known-daemon records (owner-only), the download cache, and short link
/// socket paths. Namespaced by bundle id like Cloud's state.
public struct SSHPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard(bundleID: String?) -> SSHPaths {
        SSHPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
            .appendingPathComponent("ssh-next", isDirectory: true))
    }

    public var clientState: URL { root.appendingPathComponent("link-state", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// Builds of one artifact the download cache keeps: the one in use and the last two used.
    public static let downloadsKept = 3

    /// Marks `file` (a download-cache build, `<artifact>-<commit12>`) used now and removes the
    /// same artifact's other builds past the `kept` most recently used, and their `.partial`
    /// fetches older than a day. Each build is ~97 MB and every nightly or DEV build fetches its
    /// own, so the never-pruned cache grew ~1.9 GB a day (11.9 GB, 198 builds on one Mac).
    public func pruneDownloads(using file: URL, kept: Int = SSHPaths.downloadsKept, now: Date = Date()) {
        let fm = FileManager.checked
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let name = file.lastPathComponent
        guard let dash = name.lastIndex(of: "-"), Self.isCommitPrefix(name[name.index(after: dash)...]) else { return }
        let artifact = name[...dash]
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys) else { return }
        var builds: [(url: URL, used: Date)] = []
        for entry in entries where entry.lastPathComponent != name && entry.lastPathComponent.hasPrefix(artifact) {
            let rest = entry.lastPathComponent.dropFirst(artifact.count)
            let used = (try? entry.blockingResourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if rest.hasSuffix(".partial"), Self.isCommitPrefix(rest.dropLast(".partial".count)) {
                if now.timeIntervalSince(used) > 86_400 { try? fm.removeItem(at: entry) }
            } else if Self.isCommitPrefix(rest) {
                builds.append((entry, used))
            }
        }
        for stale in builds.sorted(by: { $0.used > $1.used }).dropFirst(max(kept - 1, 0)) {
            try? fm.removeItem(at: stale.url)
        }
    }

    private static func isCommitPrefix(_ text: Substring) -> Bool {
        text.count == 12 && text.allSatisfy(\.isHexDigit)
    }

    /// The link's local v12 socket, short enough for `sun_path`.
    public func linkSocket(machineID: String) -> String {
        let hash = SHA256.hash(data: Data((root.path + machineID).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-ssh-\(hash).sock")
    }

    public func prepare() throws {
        for directory in [root, clientState, downloads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// Why ``SSHMachineLink/socketPath()`` did not return a socket.
public enum SSHLinkError: Error, Sendable, CustomStringConvertible {
    /// The machine waits for the user; see `status`.
    case blocked(SSHConnectionMachine.Status)
    case ssh(SSHFailure)
    case needsInstall(InstallNeed)
    case linkFailed(String)
    case stopped

    /// Retrying on a timer cannot help; the next try waits for an event.
    public var waitsForUser: Bool {
        switch self {
        case .blocked, .needsInstall, .stopped: true
        case .ssh(let failure): failure.kind == .authFailed || failure.kind == .hostKeyUntrusted || failure.kind == .sessionInUse
        case .linkFailed: false
        }
    }

    public var description: String {
        switch self {
        case .blocked(let status): "waiting: \(status)"
        case .ssh(let failure): failure.message
        case .needsInstall(let need): "cmux-tui needs an install: \(need)"
        case .linkFailed(let text): text
        case .stopped: "disconnected"
        }
    }
}

/// One SSH machine's link: runs the bundled `cmux-tui remote connect ssh://…`
/// (SSHCommandLine) at once and returns its local v12 socket, which the app
/// connects a `DaemonConnection` to exactly like a Cloud machine's link.
///
/// The link process owns everything from the first dial to ready: the SSH
/// probe of the machine's cmux-tui and every redial, under one budget
/// (cmuxterm-hq#7766). The app never retries any of it. It reads where the
/// link is from the link's admin socket (``SSHLinkAdmin``) each time the link
/// says a dial failed, and passes a person's deadline down to it
/// (``awaitReady(within:)``). A link that exits before it connected says why
/// once: a refusal or an SSH failure from its own output, else one SSH probe
/// that tells what the machine needs installed.
///
/// ``socketPath()`` is the connection's endpoint provider: it returns the
/// live socket or starts a new link, gated by the machine's
/// ``SSHConnectionMachine``. Every status change is reported through
/// `onStatus` (the App shows it in the sidebar).
public actor SSHMachineLink {
    public nonisolated let host: SSHHost
    public nonisolated let machineID: String
    private let binary: URL
    private let paths: SSHPaths
    private let commandLine: SSHCommandLine
    private let environment: @Sendable () async -> [String: String]
    private let onStatus: @Sendable (SSHConnectionMachine.Status) -> Void
    private var machine = SSHConnectionMachine()
    /// ``SSHConnectionMachine/waitsForUser``, mirrored at each event for readers off the actor.
    private nonisolated let waitsForUserMirror = Mutex(false)
    private var child: ChildProcess?
    /// The stderr tail of the last link that exited.
    private var exitedOutput: String?
    private var socket: String?
    /// The running link's admin socket (``SSHLinkAdmin``).
    private var admin: SSHLinkAdmin?
    private var starting: Task<String, any Error>?
    /// Invalidates in-flight startup work when transport ownership changes.
    private var startGeneration = 0
    private var localProtocol: Int?
    /// The last probe's findings (platform for the installer).
    public private(set) var lastReport: SSHProbeReport?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "ssh.link")

    public init(host: SSHHost, binary: URL, paths: SSHPaths, commandLine: SSHCommandLine = SSHCommandLine(),
                environment: @escaping @Sendable () async -> [String: String],
                onStatus: @escaping @Sendable (SSHConnectionMachine.Status) -> Void) {
        self.host = host
        machineID = host.machineID
        self.binary = binary
        self.paths = paths
        self.commandLine = commandLine
        self.environment = environment
        self.onStatus = onStatus
    }

    public var status: SSHConnectionMachine.Status { machine.status }
    /// Only Reconnect may open the gate (``SSHConnectionMachine/waitsForUser``): read without a hop,
    /// set before the status that follows it is reported.
    public nonisolated var waitsForUser: Bool { waitsForUserMirror.withLock { $0 } }

    /// The link's stderr tail (ssh and the machine's cmux-tui write their
    /// errors there, the daemon's start failure included): the running
    /// link's, else the last exited one's; nil when empty.
    public func output() -> String? {
        let text = child?.stderrText ?? exitedOutput ?? ""
        return text.isEmpty ? nil : text
    }
    public var pid: Int32? { child?.pid }

    /// Feeds an event to the gate and reports the status.
    public func handle(_ event: SSHConnectionMachine.Event) {
        let before = machine.status
        machine.handle(event)
        let waits = machine.waitsForUser
        waitsForUserMirror.withLock { $0 = waits }
        if event == .disconnect {
            startGeneration += 1
            starting?.cancel()
            starting = nil
            tearDown()
        }
        if machine.status != before { onStatus(machine.status) }
    }

    public func socketPath() async throws -> String {
        if let socket, child?.isRunning == true, FileManager.default.fileExists(atPath: socket) { return socket }
        if let starting { return try await Self.value(of: starting) }
        startGeneration += 1
        let generation = startGeneration
        let task = Task {
            // The start ends here, not when a caller stops waiting (``value(of:)``).
            defer { if self.startGeneration == generation { self.starting = nil } }
            do {
                return try await self.start(generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try self.checkStartup(generation)
                // Probe decoding, local state preparation and process launch can
                // fail before the link has a child to report an SSH error, and the
                // probe after an early exit can fail while a dial's reason shows.
                // Preserve typed remote failures, install consent and disconnect.
                if self.startGeneration == generation, self.machine.status.isDialing, !Self.reportsItself(error) {
                    self.handle(.failed(.remoteFailed(String(describing: error))))
                }
                throw error
            }
        }
        starting = task
        return try await Self.value(of: task)
    }

    /// An SSH failure or an install need already set the status that says it.
    private static func reportsItself(_ error: any Error) -> Bool {
        switch error as? SSHLinkError {
        case .ssh?, .needsInstall?, .blocked?, .stopped?: true
        case .linkFailed?, nil: false
        }
    }

    /// `task`'s value, or CancellationError as soon as the caller is cancelled: the link's first
    /// dial has no deadline here (the link owns it), so a closing daemon connection must not wait
    /// for it. The link itself goes on for the next caller.
    private static func value(of task: Task<String, any Error>) async throws -> String {
        let waiter = OnceWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.hold(continuation)
                if Task.isCancelled {
                    waiter.resume(with: .failure(CancellationError()))
                    return
                }
                // task-owner: ends with the link's start, which a disconnect cancels
                Task { waiter.resume(with: await task.result) }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
        }
    }

    /// One continuation resumed at most once, by whichever comes first.
    private final class OnceWaiter: Sendable {
        private let held = Mutex<CheckedContinuation<String, any Error>?>(nil)

        func hold(_ continuation: CheckedContinuation<String, any Error>) {
            held.withLock { $0 = continuation }
        }

        func resume(with result: Result<String, any Error>) {
            let continuation = held.withLock { held in
                defer { held = nil }
                return held
            }
            continuation?.resume(with: result)
        }
    }

    /// How long a person's open or Reconnect waits on the link before the machine shows why it is
    /// not connected yet; the link keeps dialing after it (``awaitReady(within:)``).
    public static let personDeadline: Duration = .seconds(10)

    /// A person opened or reconnected the machine: a link still on its first dial dials now, and
    /// what it answers within `deadline` (the person's) shows. Nothing when no link process runs:
    /// the daemon connection's attempt starts one.
    public func awaitReady(within deadline: Duration) async {
        guard let child, child.isRunning, socket == nil, let admin else { return }
        let state = await admin.awaitReady(within: deadline)
        reportFirstDial(state, of: child)
    }

    /// Ends the link for good (forget, quit).
    public func stop() {
        handle(.disconnect)
    }

    /// Ends the link client so it can close the remote session at once
    /// (its close frame goes over its own ssh child), then the whole process
    /// group if it has not exited within `closeDeadline` (cx-bj1o).
    private func tearDown() {
        if let child {
            child.terminateProcessOnly()
            // task-owner: one bounded fallback; terminate() is a no-op once the child exited
            Task.detached {
                // wakeup-allow: one-shot deadline for a stopped link client
                try? await Task.sleep(for: Self.closeDeadline)
                child.terminate()
            }
        }
        child = nil
        socket = nil
        admin = nil
    }

    /// How long a stopped link client may take to close its session before
    /// its process group is ended.
    static let closeDeadline: Duration = .seconds(5)

    private func start(generation: Int) async throws -> String {
        try checkStartup(generation)
        tearDown()
        handle(.attemptStarted)
        guard machine.mayAttempt else { throw SSHLinkError.blocked(machine.status) }
        let env = await environment()
        try checkStartup(generation)
        guard machine.mayAttempt else { throw SSHLinkError.stopped }
        return try await spawn(env, generation: generation)
    }

    private func checkStartup(_ generation: Int) throws {
        try Task.checkCancellation()
        guard startGeneration == generation else { throw CancellationError() }
    }

    /// One ssh round trip: platform and the machine's cmux-tui. Its failure shows as the machine's status.
    public func probe(_ env: [String: String]) async throws -> SSHProbeReport {
        do {
            return try await probeQuietly(env)
        } catch SSHLinkError.ssh(let failure) {
            try Task.checkCancellation()
            handle(.failed(failure))
            throw SSHLinkError.ssh(failure)
        }
    }

    /// One probe now whose failure shows nothing (nil): the link spawns with no probe of its own,
    /// so a connected machine's update checks read the machine here, once per connect.
    public func probedReport(_ env: [String: String]) async -> SSHProbeReport? {
        try? await probeQuietly(env)
    }

    private func probeQuietly(_ env: [String: String]) async throws -> SSHProbeReport {
        try Task.checkCancellation()
        let result: SSHProcessResult
        do {
            result = try await SSHProcessRunner.run(commandLine.script(host), input: .data(Data(SSHProbeReport.script(remoteBinary: host.remoteBinary).utf8)),
                                                 environment: env, deadline: .seconds(45), label: "ssh probe \(host.destination)")
        } catch is DeadlineExceeded {
            try Task.checkCancellation()
            throw SSHLinkError.ssh(.unreachable("ssh to \(host.destination) did not answer within 45 s"))
        }
        try Task.checkCancellation()
        if let failure = SSHFailure.classify(status: result.status, stderr: result.stderr), result.status == 255 {
            throw SSHLinkError.ssh(failure)
        }
        guard let report = SSHProbeReport.parse(stdout: result.stdout) else {
            throw SSHLinkError.ssh(SSHFailure.classify(status: result.status == 0 ? 1 : result.status, stderr: result.stderr)
                ?? .remoteFailed("the remote shell gave no probe output"))
        }
        lastReport = report
        return report
    }

    /// The bundled cmux-tui's link protocol, read once.
    private func bundledProtocol(_ env: [String: String]) async throws -> Int {
        if let localProtocol { return localProtocol }
        let result = try await SSHProcessRunner.run([binary.path, "remote-probe", "--json"], environment: env, deadline: .seconds(10),
                                                 label: "cmux-tui remote-probe")
        try Task.checkCancellation()
        let value = try RemoteProbe.decode(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).remoteProtocol
        localProtocol = value
        return value
    }

    private func spawn(_ env: [String: String], generation: Int) async throws -> String {
        try paths.prepare()
        let path = paths.linkSocket(machineID: machineID)
        unlink(path)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw SSHLinkError.linkFailed("cmux-tui not found at \(binary.path)")
        }
        let child = ChildProcess(executable: binary,
                                 arguments: commandLine.link(host, clientStateDir: paths.clientState.path, localSocket: path),
                                 environment: env)
        try child.start()
        self.child = child
        admin = SSHLinkAdmin(localSocket: path)
        watchFirstDial(child)
        // No deadline here: the link dials under its own budget until it connects or exits.
        var connected: String?
        for await line in child.lines {
            if case .connected(let socket) = CloudLinkEvent.parse(line) {
                connected = socket
                break
            }
        }
        try checkStartup(generation)
        guard let socket = connected else {
            _ = await child.waitForExit()
            if self.child === child { self.child = nil; admin = nil }
            try checkStartup(generation)
            throw try await linkExitedBeforeReady(child, env, generation: generation)
        }
        guard machine.mayAttempt, self.child === child else {
            // A disconnect that raced the connected line already ran
            // tearDown for this child; otherwise stop it the same way, so
            // the client still closes its new session (cx-bj1o).
            if self.child === child { tearDown() }
            throw SSHLinkError.stopped
        }
        self.socket = socket
        handle(.linkUp)
        watchExit(child)
        watchSnapshots(child)
        logger.info("ssh link up for \(self.host.destination.description, privacy: .public) pid \(child.pid ?? 0)")
        return socket
    }

    /// The link exited before it connected: a permanent failure (Rust redials every other one).
    /// Says why once: a typed refusal or ssh's own failure from its output, else one SSH probe
    /// tells what the machine needs installed; that probe's own failure shows as it is. Nothing
    /// here retries: the next attempt waits for a person, app activation or an install.
    private func linkExitedBeforeReady(_ child: ChildProcess, _ env: [String: String], generation: Int) async throws -> SSHLinkError {
        exitedOutput = child.stderrText
        // What ended it, without the failed dials it redialed before (`…; redialing`).
        let stderr = child.stderrText.split(whereSeparator: \.isNewline).filter { !$0.hasSuffix("; redialing") }.joined(separator: "\n")
        logger.error("ssh link for \(self.host.destination.description, privacy: .public) ended before it connected: \(stderr, privacy: .public)")
        if let refusal = RemoteRefusal.parse(stderr) {
            // A typed refusal is an install or update state, not a failure (cx-z3zh).
            handle(.probed(.refused(refusal)))
            return .needsInstall(.refused(refusal))
        }
        let failure = SSHFailure.classifyLink(stderr: stderr)
        if let failure, failure.kind != .remoteFailed {
            handle(.failed(failure))
            return .ssh(failure)
        }
        let report = try await probe(env)
        try checkStartup(generation)
        let need = InstallNeed.assess(report, localProtocol: try await bundledProtocol(env))
        try checkStartup(generation)
        if need != .none {
            handle(.probed(need))
            return .needsInstall(need)
        }
        let cause = failure ?? .remoteFailed(stderr.isEmpty ? "cmux-tui remote connect \(host.destination) exited" : stderr)
        handle(.failed(cause))
        return .ssh(cause)
    }

    /// While the link dials its first connection it says on stderr each time a dial failed and it
    /// redials; each such line reads the link's state, so the machine shows the reason while the
    /// link keeps trying (it stays eligible: no gate closes).
    private func watchFirstDial(_ child: ChildProcess) {
        let lines = child.stderrLines
        // task-owner: ends with the child's stderr, or at its first line after the link connected
        Task { [weak self] in
            for await _ in lines {
                guard let self, await self.readFirstDial(child) else { return }
            }
        }
    }

    /// Reads the link's state for a failed first dial; false once the link connected or was replaced.
    private func readFirstDial(_ reading: ChildProcess) async -> Bool {
        guard child === reading, socket == nil, let admin else { return false }
        let state = await admin.linkState()
        reportFirstDial(state, of: reading)
        return child === reading && socket == nil
    }

    /// A first dial that failed and goes on shows its reason as unreachable (the link redials it).
    private func reportFirstDial(_ state: SSHLinkState?, of reading: ChildProcess) {
        guard child === reading, socket == nil, let reason = state?.redialReason else { return }
        let text: String
        if case .unreachable(let line)? = SSHFailure.classifyLink(stderr: reason) { text = line } else { text = reason }
        handle(.failed(.unreachable(text)))
    }

    /// A link that exits (it crashed, or its session is gone) reports it; the
    /// daemon connection's next attempt then calls ``socketPath()``, which
    /// starts it again: the only restart of a link client.
    private func watchExit(_ child: ChildProcess) {
        Task { [weak self] in
            _ = await child.waitForExit()
            await self?.linkExited(child)
        }
    }

    /// The running link client redials on its own after sleep, a network
    /// drop or change, and its local socket stays up meanwhile; only its
    /// snapshots say so. The machine reads as reconnecting until it is back.
    private func watchSnapshots(_ child: ChildProcess) {
        let lines = child.lines
        // task-owner: ends with the child's stdout
        Task { [weak self] in
            for await line in lines {
                guard let connected = CloudLinkEvent.linkConnected(line) else { continue }
                await self?.linkReported(child, connected: connected)
            }
        }
    }

    private func linkReported(_ reporting: ChildProcess, connected: Bool) {
        guard child === reporting else { return }
        if connected {
            if machine.status == .reconnecting { handle(.linkUp) }
        } else {
            handle(.linkInterrupted)
        }
    }

    private func linkExited(_ exited: ChildProcess) {
        guard child === exited else { return }
        exitedOutput = exited.stderrText
        child = nil
        socket = nil
        handle(.linkLost)
    }
}

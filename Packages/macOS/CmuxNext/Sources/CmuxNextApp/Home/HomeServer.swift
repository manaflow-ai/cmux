import CmuxNextWakeups
import Foundation
import os

/// The local mux server (`mux home`, mux/local) that Home shows. One per
/// app: started when Home first opens, stopped at quit. It gets a terminal's
/// environment (login `PATH`, this app's `CMUX_SOCKET_PATH` and CLI), so the
/// mux's `mux cmux ...` controls this app. The app holds the child's stdin;
/// with `MUX_EXIT_ON_STDIN_EOF=1` the server exits when that closes, so a
/// crashed app leaves no server behind. Readiness is the server's
/// `mux home: ready` line, not a probe.
@MainActor
final class HomeServer {
    private let environment: @Sendable () async -> [String: String]
    private let deadline: DemandTimer
    private let readyTimeout: Duration
    private let home: String
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    private var process: Process?
    private var stdin: FileHandle?
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(environment: @escaping @Sendable () async -> [String: String],
         clock: any Clock<Duration> = ContinuousClock(), readyTimeout: Duration = .seconds(15),
         home: String = NSHomeDirectory()) {
        self.environment = environment
        self.home = home
        deadline = DemandTimer(owner: "HomeServer.ready", clock: clock)
        self.readyTimeout = readyTimeout
    }

    /// Returns when the server says it is ready, or when it cannot start
    /// (exited, `mux` not installed, timeout). Home then loads the URL
    /// either way: a server started elsewhere on the port also answers.
    func ensureRunning() async {
        // Running and nobody waiting: ready, or it missed the deadline and
        // Retry should just load the page again.
        if stopped || process?.isRunning == true && waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 { Task { await start() } }
        }
    }

    /// At quit: closing stdin ends the server; terminate covers a server
    /// that does not read it (one not started by `mux home`).
    func stop() {
        stopped = true
        try? stdin?.close()
        process?.terminate()
        process = nil
        finish()
    }

    /// The running server's pid, for tests.
    var processIdentifier: Int32? { process?.processIdentifier }

    private func start() async {
        let env = Self.serverEnvironment(terminal: await environment(), app: ProcessInfo.processInfo.environment)
        guard !stopped else { return finish() }
        guard let executable = Self.muxExecutable(path: env["PATH"], home: home) else {
            logger.error("mux home: no `mux` on PATH or in ~/.local/bin; run `mux install` in mux/cli")
            return finish()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["home"]
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let lines = LineSplitter()
        output.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            // concurrency-allow: the pipe's own reader queue, never the main thread.
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = lines.append(data)
            Task { @MainActor in self?.received(text) }
        }
        process.terminationHandler = { @Sendable [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.exited(process, status: status) }
        }
        do {
            try process.run()
        } catch {
            logger.error("mux home: \(String(describing: error), privacy: .public)")
            return finish()
        }
        // The child has its copy; ours would hold the pipe open after a crash.
        try? input.fileHandleForReading.close()
        self.process = process
        stdin = input.fileHandleForWriting
        logger.info("mux home: started \(executable.path, privacy: .public) (\(process.processIdentifier))")
        let timeout = readyTimeout
        deadline.schedule(after: timeout) { @MainActor [weak self] in
            self?.logger.error("mux home: no ready line after \(timeout, privacy: .public)")
            self?.finish()
        }
    }

    private func received(_ lines: [String]) {
        for line in lines {
            logger.info("\(line, privacy: .public)")
            if line.hasPrefix("mux home: ready") {
                isReady = true
                finish()
            }
        }
    }

    private func exited(_ ended: Process, status: Int32) {
        logger.info("mux home: exited \(status)")
        guard ended === process else { return }
        process = nil
        stdin = nil
        isReady = false
        finish()
    }

    private func finish() {
        deadline.cancel()
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// A terminal's environment made fit for a background server: the
    /// process identity a PTY would add (`HOME`, `USER`, ...) from the app,
    /// and none of the keys that describe a terminal session.
    nonisolated static func serverEnvironment(terminal: [String: String], app: [String: String]) -> [String: String] {
        var env = terminal.filter { key, _ in !terminalSessionKeys.contains(key) }
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] where env[key] == nil {
            env[key] = app[key]
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        env["MUX_EXIT_ON_STDIN_EOF"] = "1"
        return env
    }

    nonisolated static let terminalSessionKeys: Set<String> = [
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "TERMINFO",
        "PWD", "OLDPWD", "SHLVL", "ZDOTDIR", "GHOSTTY_SHELL_FEATURES",
    ]

    /// The `mux` launcher (`mux install` writes ~/.local/bin/mux).
    nonisolated static func muxExecutable(path: String?, home: String = NSHomeDirectory(),
                                          isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let directories = (path ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin"]
        return directories.lazy.map { $0 + "/mux" }.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}

/// Splits pipe output into complete lines; called from the pipe's queue only.
private nonisolated final class LineSplitter: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

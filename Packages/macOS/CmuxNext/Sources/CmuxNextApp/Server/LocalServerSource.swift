import CmuxNextDaemon
import CmuxNextServer
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import SystemConfiguration

/// A file watch the source re-reads on (kernel vnode events, no polling).
protocol ServerFileWatching: AnyObject {
    func start()
    func stop()
}

extension ConfigFileWatcher: ServerFileWatching {}

/// This Mac's own `server.status` (plans/cmux-next/server.md 3 and 13): the
/// bundled `cmux` CLI's `server status --json` plus the process roles of
/// `host roles --json`, mapped by `LocalServerStatus`. It reads again when
/// the roles status file or the server config changes and after each
/// intent; never on a timer. A missing CLI, or a CLI without the server
/// verbs, reports `.unavailable`.
///
/// Intents reach it only from `ServerModel`, which only the menu bar
/// views drive, so a fix is always a user's click (the action catalog has
/// no fix action, so MCP and the socket cannot start one).
@MainActor
final class LocalServerSource: ServerSource {
    nonisolated struct CLIResult: Sendable, Equatable {
        var status: Int32
        var stdout: Data
    }

    /// Runs the CLI once off the main actor; nil when it could not start or ran out of time.
    typealias RunCLI = @concurrent @Sendable (_ executable: URL, _ arguments: [String]) async -> CLIResult?
    /// Runs a check's fix; nil on success, else the user-facing refusal.
    typealias Fix = @MainActor (_ check: HealthCheckID) async -> String?
    typealias MakeWatcher = @MainActor (_ file: URL, _ onChange: @escaping @Sendable () -> Void) -> any ServerFileWatching
    /// The kernel vnode watch (`ConfigFileWatcher`) every App source uses.
    static let fileWatcher: MakeWatcher = { file, onChange in ConfigFileWatcher(url: file, onChange: onChange) }

    nonisolated static let statusArguments = ["server", "status", "--json"]
    nonisolated static let rolesArguments = ["host", "roles", "--json"]
    /// The CLI's usage exit code: this `cmux` has no `server` or `host` verbs.
    nonisolated static let usageExit: Int32 = 2

    private let binary: URL?
    private let hostName: String
    private let watchedFiles: [URL]
    private let runCLI: RunCLI
    private let fix: Fix
    private let makeWatcher: MakeWatcher
    private let localFixes: [HealthCheckID: HealthFix]
    /// The app's main-thread scheduler: each read's and fix's answer is a task on it.
    private let mainWork: MainWorkScheduler
    private var sink: (@MainActor (ServerSourceEvent) -> Void)?
    private var watchers: [any ServerFileWatching] = []
    private var reading: Task<Void, Never>?
    private var readAgain = false
    /// Bumped by `stop()`: a read answered after it (from before a restart) applies nothing.
    private var readGeneration = 0
    private var work: [String: Task<Void, Never>] = [:]
    private var lastSnapshot: ServerSnapshot?
    private var lastUnavailable: String?

    init(binary: URL?, hostName: String, watchedFiles: [URL], runCLI: @escaping RunCLI,
         fix: @escaping Fix, makeWatcher: @escaping MakeWatcher, localFixes: [HealthCheckID: HealthFix] = [:],
         mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
        self.binary = binary
        self.hostName = hostName
        self.watchedFiles = watchedFiles
        self.runCLI = runCLI
        self.fix = fix
        self.makeWatcher = makeWatcher
        self.localFixes = localFixes
    }

    /// The App's source: the bundled CLI, the user-mode server's files, and
    /// fixes through the privileged helper.
    static func app(mainWork: MainWorkScheduler, fixer: ServerHealthFixer) -> LocalServerSource {
        // SAFETY: the encoding pointer is nil, so SCDynamicStoreCopyComputerName writes no caller memory; the
        // copied string is bridged with its +1.
        LocalServerSource(
            binary: bundledCLI(),
            hostName: (unsafe SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
            watchedFiles: watchedFiles(home: FileManager.default.homeDirectoryForCurrentUser),
            runCLI: { executable, arguments in await runProcess(executable, arguments) },
            fix: { await fixer.fix($0) },
            makeWatcher: fileWatcher,
            localFixes: ServerHealthFixer.localFixes,
            mainWork: mainWork)
    }

    /// `Contents/Resources/bin/cmux`, or nil when this build does not carry it.
    static func bundledCLI(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The user-mode server's files on macOS (cmux-server-core layout): the
    /// process roles status `<state>/roles/status.json` and `server.json`.
    nonisolated static func watchedFiles(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Application Support/cmux/server/roles/status.json"),
            home.appendingPathComponent(".config/cmux/server.json"),
        ]
    }

    // MARK: - ServerSource

    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {
        self.sink = sink
        let mainWork = mainWork
        watchers = watchedFiles.map { file in
            // The server process rewrote its status: one visible read task (refresh coalesces reads).
            makeWatcher(file) { [weak self] in
                mainWork.postFromAnyThread(.visible, owner: "LocalServerSource.fileChanged") { [weak self] in self?.refresh() }
            }
        }
        watchers.forEach { $0.start() }
        refresh()
    }

    func send(_ intent: ServerIntent) {
        switch intent.kind {
        case let .fixCheck(check):
            let mainWork = mainWork, key = intent.key
            // task-owner: LocalServerSource, one helper request per intent; cancelled by stop().
            // The fix is the person's click: its answer is the rest of their action (userBlocking).
            work[key] = Task { @concurrent [weak self] in
                let reject = await self?.runFix(check) ?? nil
                mainWork.postFromAnyThread(.userBlocking, owner: "LocalServerSource.fixed") { [weak self] in
                    self?.work[key] = nil
                    self?.settle(key, reject: reject)
                }
            }
        case .openHealth:
            settle(intent.key, reject: nil)
        case .setEnabled, .showPairingCode, .lookupCode, .approveCode, .revokeDevice:
            settle(intent.key, reject: RefusalStrings.text("refusal.server.controlNotYet", "This server control is not available yet."))
        }
    }

    func stop() {
        watchers.forEach { $0.stop() }
        watchers = []
        reading?.cancel()
        reading = nil
        readAgain = false
        readGeneration &+= 1
        for task in work.values { task.cancel() }
        work = [:]
        sink = nil
        lastSnapshot = nil
        lastUnavailable = nil
    }

    /// Runs `check`'s fix (the helper's own main-actor steps); nil on success, else the refusal.
    private func runFix(_ check: HealthCheckID) async -> String? {
        await fix(check)
    }

    /// Reads the status again; a read already running reads once more after it.
    func refresh() {
        guard sink != nil else { return }
        guard reading == nil else {
            readAgain = true
            return
        }
        let binary = binary, hostName = hostName, runCLI = runCLI, localFixes = localFixes
        let mainWork = mainWork, generation = readGeneration
        // task-owner: LocalServerSource, one status read at a time; cancelled by stop().
        // The CLI runs off the main thread; its answer is one visible task.
        reading = Task { @concurrent [weak self] in
            let event = await Self.read(binary: binary, hostName: hostName, runCLI: runCLI, localFixes: localFixes)
            guard !Task.isCancelled else { return }
            mainWork.postFromAnyThread(.visible, owner: "LocalServerSource.read") { [weak self] in
                self?.readFinished(event, generation: generation)
            }
        }
    }

    /// One read answered: shows it, then runs the read asked for meanwhile.
    private func readFinished(_ event: ServerSourceEvent, generation: Int) {
        guard generation == readGeneration else { return }
        reading = nil
        emit(event)
        if readAgain {
            readAgain = false
            refresh()
        }
    }

    // MARK: - Reading

    /// One read: both CLI calls at once, then the pure mapping.
    /// `localFixes` replaces the fix of an alert whose check this app fixes
    /// itself (the button names what the click runs).
    @concurrent nonisolated static func read(binary: URL?, hostName: String, runCLI: RunCLI,
                                             localFixes: [HealthCheckID: HealthFix] = [:]) async -> ServerSourceEvent {
        guard let binary else {
            return .connection(.unavailable(RefusalStrings.text("refusal.server.cliMissing", "This build does not include the cmux command-line tool.")))
        }
        async let status = runCLI(binary, statusArguments)
        async let roles = runCLI(binary, rolesArguments)
        let statusResult = await status
        let rolesResult = await roles
        guard let statusResult, statusResult.status == 0 else {
            return .connection(.unavailable(statusResult?.status == usageExit ? notInBuild : statusFailed))
        }
        // `host roles` exits 3 before the supervisor wrote its first status: no process roles yet.
        let rolesData = rolesResult?.status == 0 ? rolesResult?.stdout : nil
        do {
            var snapshot = try LocalServerStatus.snapshot(status: statusResult.stdout, roles: rolesData, hostName: hostName)
            for index in snapshot.alerts.indices {
                if let fix = localFixes[snapshot.alerts[index].check] { snapshot.alerts[index].fix = fix }
            }
            return .snapshot(snapshot)
        } catch is LocalServerStatus.NotServerStatus {
            return .connection(.unavailable(notInBuild))
        } catch {
            return .connection(.unavailable(statusFailed))
        }
    }

    private nonisolated static var notInBuild: String {
        RefusalStrings.text("refusal.server.notInBuild", "This build does not include the server software yet.")
    }

    private nonisolated static var statusFailed: String {
        RefusalStrings.text("refusal.server.statusFailed", "Could not read the server status.")
    }

    @concurrent nonisolated static func runProcess(_ executable: URL, _ arguments: [String]) async -> CLIResult? {
        guard let result = try? await ProcessRunner.run(executable: executable, arguments: arguments, environment: nil,
                                                        timeout: .seconds(15), clock: ContinuousClock())
        else { return nil }
        return CLIResult(status: result.status, stdout: result.stdout)
    }

    // MARK: - Events

    private func emit(_ event: ServerSourceEvent) {
        switch event {
        case let .snapshot(snapshot):
            guard snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            lastUnavailable = nil
        case let .connection(.unavailable(reason)):
            guard reason != lastUnavailable else { return }
            lastUnavailable = reason
            lastSnapshot = nil
        default:
            break
        }
        sink?(event)
    }

    /// Settles an intent, then reads the status again (an intent may change it).
    private func settle(_ key: String, reject: String?) {
        sink?(.settled(key: key, reject: reject))
        refresh()
    }
}

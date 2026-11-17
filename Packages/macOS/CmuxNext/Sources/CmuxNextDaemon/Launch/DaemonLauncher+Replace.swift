import CmuxNextCompat
import Foundation

/// "Restart cmux-tui" (cx-jniyz.1): `server ensure --replace-unresponsive`
/// stops a session owner that accepts connections but never answers, then
/// ensures as usual (status `replaced`, or `running`/`started` when nothing
/// was stuck). The app offers it once a plain ensure failed (``EnsureOutcome``),
/// so the person has a way out whatever stopped the start (a full disk too, restore
/// fuzz h2); it restarts by itself only after ensures failed the way a stuck owner
/// makes them fail (the daemon's restore bound passed, or no answer). The owner's
/// terminal hosts survive a replace and the next owner adopts them.
extension DaemonLauncher {
    /// `server ensure --replace-unresponsive` refused (exit 3, `server.replace_*`):
    /// the owner was not stopped.
    public struct ReplaceRefusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var code: String
        public var message: String?
        public var description: String { "\(message ?? "replace refused") [\(code)]" }
        /// The app's own refusal: app health held the replace when it was about to start (``replaceUnresponsive(unlessHeld:)``).
        public static let heldCode = "app.replace_held"
    }

    /// The longest a replace stays silent on stdout before its first line:
    /// the 10 s identify probe, 5 s after SIGTERM and 5 s after SIGKILL, plus margin.
    static let replaceSilence: Duration = .seconds(30)

    /// Runs the app's `server ensure` with `--replace-unresponsive` and
    /// returns its result. Throws ``ReplaceRefusal`` when the owner was not
    /// stopped, and the usual ensure errors when the new owner did not start.
    /// `held`: asked again just before the replace starts (the automatic restart passes app health's
    /// ``AppHealth/holdsReplace``), so a restore that made progress since the caller checked is not
    /// replaced; true refuses with ``ReplaceRefusal/heldCode``. Past that point the replace's own
    /// probe decides: it stops only an owner that does not answer.
    @concurrent public func replaceUnresponsive(unlessHeld held: (@Sendable () -> Bool)? = nil) async throws -> EnsureResult {
        async let reapGrace = supportsReapGrace()
        let environment = await ensureEnvironment()
        let progress = configuration.binaryIsBundled
        let arguments = Self.ensureArguments(configuration, reapGrace: await reapGrace, progress: progress)
            + ["--replace-unresponsive"]
        // The new owner's restore shows as an ensure's does (``EnsureOutcome/restoring``).
        let reports = progress ? ensureOutcome.restoreReporter() : nil
        defer { reports?.end() }
        // App health reads a replace as it reads an ensure (Codex's review of #39247 at 2903cec): the new
        // owner's restore progress holds the automatic replace, and its ready or a failed start ends the hold.
        let note = health.map(EnsureProgressNote.init)
        do {
            // The last moment the app decides (Codex's review of #39247 at f02e048): the caller's check ran before its claim.
            if held?() == true { throw ReplaceRefusal(code: ReplaceRefusal.heldCode, message: "the owner is restoring and still makes progress") }
            // No progress line while the old owner is probed and stopped: the
            // silence bound covers that, then restore progress bounds the rest.
            let result = try await ProcessRunner.run(
                executable: configuration.binary,
                arguments: arguments,
                environment: environment,
                stdin: configuration.installKey?.payload,
                timeout: progress ? nil : Self.ensureRestoreCap + Self.replaceSilence,
                progressIdle: progress ? Self.replaceSilence : nil,
                progressed: note.map { note in { @Sendable in note.progressed() } },
                stdoutLine: reports?.line,
                clock: clock
            )
            if result.status != 0, let failure = Self.ensureFailure(result), failure.code.hasPrefix("server.replace_") {
                throw ReplaceRefusal(code: failure.code, message: failure.message)
            }
            let ensured = try Self.parseEnsure(result)
            health?.note(.ready(pid: ensured.pid))
            ensureOutcome.note(nil, pid: ensured.pid)
            return ensured
        } catch {
            // A refused replace stopped nothing: the old owner (restoring, maybe) still runs.
            if !(error is ReplaceRefusal) { health?.note(.exited) }
            throw error
        }
    }

    /// ``ensure()`` for the endpoint provider, recording how it ended in ``ensureOutcome``.
    func ensureRecordingOutcome() async throws -> EnsureResult {
        do {
            let ensured = try await ensure()
            ensureOutcome.note(nil, pid: ensured.pid)
            return ensured
        } catch {
            // A cancelled ensure (its connection torn down, or shutdown) says nothing about the owner.
            if !Task.isCancelled, !(error is CancellationError) {
                let free = DaemonStartFailure.freeBytes(at: configuration.stateDirectory ?? configuration.runtimeBase)
                ensureOutcome.note(error, freeBytes: free)
            }
            throw error
        }
    }

    /// One plain `server ensure` whose outcome feeds ``ensureOutcome`` (and so ``UnresponsiveOwnerWatch``), its
    /// result dropped: the probe of a connected owner that leaves its heartbeat unanswered while its connection
    /// stays open (``DaemonRecovery``), as the reconnect's ensure was while a missed heartbeat closed the connection.
    public func probeOwner() async {
        _ = try? await ensureRecordingOutcome()
    }

    /// The JSON error of a failed `server ensure` (the last JSON line on stderr).
    static func ensureFailure(_ result: ProcessResult) -> EnsureFailure? {
        let line = String(decoding: result.stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        return line.flatMap { try? JSONDecoder().decode(EnsureFailure.self, from: Data($0.utf8)) }
    }

    /// True for a plain ensure failure a stuck owner causes: the restore bound
    /// passed (`server.restore_timeout`), the ensure itself got no answer in
    /// time, no owner became ready (`server.unavailable`), or the owner refused
    /// every connection at its connection limit (`server.busy`, issue 22311).
    static func isStuckOwnerFailure(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .sessionRestoreTimedOut?, .timedOut?: true
        case .launchFailed(let detail)?:
            detail.contains("\"server.unavailable\"") || detail.contains("\"server.busy\"")
        default: false
        }
    }
}

/// How the launcher's last `server ensure` ended: whether it failed (``failure``, the gate of
/// "Restart cmux-tui" while no daemon runs, restore fuzz h2) and whether it failed the way a stuck
/// owner makes it fail (``DaemonLauncher/isStuckOwnerFailure(_:)``, the automatic restart's
/// input). Shared by every copy of one launcher.
public final class EnsureOutcome: Sendable {
    private struct State {
        var ownerLooksStuck = false
        var failure: DaemonStartFailure?
        /// Ensures that failed in a row since the last one that worked.
        var failedInARow = 0
        var observer: (@MainActor @Sendable () -> Void)?
        /// Gets every ensure's outcome (the automatic restart, ``UnresponsiveOwnerWatch``).
        var watch: UnresponsiveOwnerWatch?
        /// The running ensure's last restore progress line (``restoring``).
        var restoring: RestoreProgressReport?
        /// The ensure whose lines ``restoring`` takes: each ``restoreReporter()`` takes the next, so a line
        /// or an end of an earlier one that lands late changes nothing.
        var restoreEnsure: UInt64 = 0
        var restoringObserver: (@MainActor @Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    /// The last ensure failed as a stuck owner makes it fail; false after one that succeeded.
    public var ownerLooksStuck: Bool { state.withLock { $0.ownerLooksStuck } }

    /// Why the last ensure failed; nil after one that succeeded (or before any ran).
    public var failure: DaemonStartFailure? { state.withLock { $0.failure } }

    /// How many ensures failed in a row since the last one that worked (0 after one that worked).
    public var failedInARow: Int { state.withLock { $0.failedInARow } }

    /// Calls `observer` on the main actor after each change of ``ownerLooksStuck``, ``failure`` or
    /// ``failedInARow`` (so after every failed ensure).
    public func observe(_ observer: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.observer = observer }
    }

    /// The session owner the running `server ensure` waits for is restoring: its last progress line.
    /// Nil once that ensure ended (whether or not it worked) and while no ensure reported one.
    public var restoring: RestoreProgressReport? { state.withLock { $0.restoring } }

    /// Calls `observer` on the main actor after each change of ``restoring`` (every progress line, about every
    /// 5 s while an owner restores, and once when the ensure ends).
    public func observeRestoring(_ observer: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.restoringObserver = observer }
    }

    /// One `server ensure --restore-progress`: `line` takes each stdout line (``ProcessRunner/run``'s
    /// `stdoutLine`) and publishes the restore progress lines in ``restoring``; `end` clears it when the
    /// ensure ends. Only the latest ensure's lines count.
    func restoreReporter() -> (line: @Sendable (String) -> Void, end: @Sendable () -> Void) {
        let ensure = state.withLock { state -> UInt64 in
            state.restoreEnsure &+= 1
            return state.restoreEnsure
        }
        return ({ [weak self] line in
            guard let report = RestoreProgressReport.parse(line) else { return }
            self?.noteRestoring(report, ensure: ensure)
        }, { [weak self] in
            self?.noteRestoring(nil, ensure: ensure)
        })
    }

    private func noteRestoring(_ report: RestoreProgressReport?, ensure: UInt64) {
        let observer = state.withLock { state -> (@MainActor @Sendable () -> Void)? in
            guard state.restoreEnsure == ensure, state.restoring != report else { return nil }
            state.restoring = report
            return state.restoringObserver
        }
        guard let observer else { return }
        // task-owner: one main-actor hop per progress line (about every 5 s); the observer reads the current value
        Task { @MainActor in observer() }
    }

    /// Feeds every ensure's outcome to `watch`, which restarts an owner that stays stuck.
    public func follow(_ watch: UnresponsiveOwnerWatch) {
        state.withLock { $0.watch = watch }
    }

    /// Records how an ensure ended (nil: it succeeded, finding or starting the owner `pid`).
    /// `freeBytes`: the free space on the state's volume after a failure (nil: unknown).
    func note(_ error: (any Error)?, pid: Int32? = nil, freeBytes: UInt64? = nil) {
        let stuck = error.map(DaemonLauncher.isStuckOwnerFailure) ?? false
        let failure = error.map { DaemonStartFailure($0, freeBytes: freeBytes) }
        let (observer, watch) = state.withLock { state -> ((@MainActor @Sendable () -> Void)?, UnresponsiveOwnerWatch?) in
            let failedInARow = failure == nil ? 0 : state.failedInARow + 1
            guard state.ownerLooksStuck != stuck || state.failure != failure || state.failedInARow != failedInARow else {
                return (nil, state.watch)
            }
            state.ownerLooksStuck = stuck
            state.failure = failure
            state.failedInARow = failedInARow
            return (state.observer, state.watch)
        }
        watch?.note(UnresponsiveOwnerWatch.Ensure(error, pid: pid))
        guard let observer else { return }
        // task-owner: one main-actor hop per change; the observer reads the current value
        Task { @MainActor in observer() }
    }
}

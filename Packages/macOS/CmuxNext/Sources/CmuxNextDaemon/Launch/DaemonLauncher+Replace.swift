import CmuxNextCompat
import Foundation

/// "Restart cmux-tui" (cx-jniyz.1): `server ensure --replace-unresponsive`
/// stops a session owner that accepts connections but never answers, then
/// ensures as usual (status `replaced`, or `running`/`started` when nothing
/// was stuck). The verb cannot tell a stuck owner from one still restoring,
/// so the app offers it only after a plain ensure failed the way a stuck owner
/// makes it fail (``EnsureOutcome``): the daemon's restore bound passed, or no
/// answer. The owner's terminal hosts survive a replace and the next owner
/// adopts them.
extension DaemonLauncher {
    /// `server ensure --replace-unresponsive` refused (exit 3, `server.replace_*`):
    /// the owner was not stopped.
    public struct ReplaceRefusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var code: String
        public var message: String?
        public var description: String { "\(message ?? "replace refused") [\(code)]" }
    }

    /// The longest a replace stays silent on stdout before its first line:
    /// the 10 s identify probe, 5 s after SIGTERM and 5 s after SIGKILL, plus margin.
    static let replaceSilence: Duration = .seconds(30)

    /// Runs the app's `server ensure` with `--replace-unresponsive` and
    /// returns its result. Throws ``ReplaceRefusal`` when the owner was not
    /// stopped, and the usual ensure errors when the new owner did not start.
    @concurrent public func replaceUnresponsive() async throws -> EnsureResult {
        async let reapGrace = supportsReapGrace()
        let environment = await ensureEnvironment()
        let progress = configuration.binaryIsBundled
        let arguments = Self.ensureArguments(configuration, reapGrace: await reapGrace, progress: progress)
            + ["--replace-unresponsive"]
        // No progress line while the old owner is probed and stopped: the
        // silence bound covers that, then restore progress bounds the rest.
        let result = try await ProcessRunner.run(
            executable: configuration.binary,
            arguments: arguments,
            environment: environment,
            stdin: configuration.installKey?.payload,
            timeout: Self.ensureRestoreCap + Self.replaceSilence,
            progressIdle: progress ? Self.replaceSilence : nil,
            clock: clock
        )
        if result.status != 0, let failure = Self.ensureFailure(result), failure.code.hasPrefix("server.replace_") {
            throw ReplaceRefusal(code: failure.code, message: failure.message)
        }
        let ensured = try Self.parseEnsure(result)
        ensureOutcome.note(nil, pid: ensured.pid)
        return ensured
    }

    /// ``ensure()`` for the endpoint provider, recording how it ended in ``ensureOutcome``.
    func ensureRecordingOutcome() async throws -> EnsureResult {
        do {
            let ensured = try await ensure()
            ensureOutcome.note(nil, pid: ensured.pid)
            return ensured
        } catch {
            // A cancelled ensure (its connection torn down, or shutdown) says nothing about the owner.
            if !Task.isCancelled, !(error is CancellationError) { ensureOutcome.note(error) }
            throw error
        }
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
    /// time, or no owner became ready (`server.unavailable`).
    static func isStuckOwnerFailure(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .sessionRestoreTimedOut?, .timedOut?: true
        case .launchFailed(let detail)?: detail.contains("\"server.unavailable\"")
        default: false
        }
    }
}

/// Whether the launcher's last `server ensure` failed the way a stuck owner
/// makes it fail (``DaemonLauncher/isStuckOwnerFailure(_:)``), the gate of
/// "Restart cmux-tui". Shared by every copy of one launcher.
public final class EnsureOutcome: Sendable {
    private struct State {
        var ownerLooksStuck = false
        var observer: (@MainActor @Sendable () -> Void)?
        /// Gets every ensure's outcome (the automatic restart, ``UnresponsiveOwnerWatch``).
        var watch: UnresponsiveOwnerWatch?
    }

    private let state = Mutex(State())

    public init() {}

    /// The last ensure failed as a stuck owner makes it fail; false after one that succeeded.
    public var ownerLooksStuck: Bool { state.withLock { $0.ownerLooksStuck } }

    /// Calls `observer` on the main actor after each change of ``ownerLooksStuck``.
    public func observe(_ observer: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.observer = observer }
    }

    /// Feeds every ensure's outcome to `watch`, which restarts an owner that stays stuck.
    public func follow(_ watch: UnresponsiveOwnerWatch) {
        state.withLock { $0.watch = watch }
    }

    /// Records how an ensure ended (nil: it succeeded, finding or starting the owner `pid`).
    func note(_ error: (any Error)?, pid: Int32? = nil) {
        let stuck = error.map(DaemonLauncher.isStuckOwnerFailure) ?? false
        let (observer, watch) = state.withLock { state -> ((@MainActor @Sendable () -> Void)?, UnresponsiveOwnerWatch?) in
            guard state.ownerLooksStuck != stuck else { return (nil, state.watch) }
            state.ownerLooksStuck = stuck
            return (state.observer, state.watch)
        }
        watch?.note(UnresponsiveOwnerWatch.Ensure(error, pid: pid))
        guard let observer else { return }
        // task-owner: one main-actor hop per change; the observer reads the current value
        Task { @MainActor in observer() }
    }
}

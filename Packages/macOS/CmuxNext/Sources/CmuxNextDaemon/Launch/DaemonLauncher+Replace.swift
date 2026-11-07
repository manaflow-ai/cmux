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
    public struct ReplaceRefusal: Error, Sendable, Equatable, Decodable, CustomStringConvertible {
        public var code: String
        public var message: String?
        public var description: String { "\(message ?? "replace refused") [\(code)]" }
    }

    /// Runs the app's `server ensure` with `--replace-unresponsive` and
    /// returns its result. Throws ``ReplaceRefusal`` when the owner was not
    /// stopped, and the usual ensure errors when the new owner did not start.
    /// No progress line comes while the old owner is probed and stopped: the
    /// launch rules' silence bound covers that, then restore progress bounds the rest.
    @concurrent public func replaceUnresponsive() async throws -> EnsureResult {
        let environment = try await ensureEnvironment().environment
        let ensured = try await runEnsure(environment: environment, replace: true)
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
}

/// How the launcher's last `server ensure` ended: whether it failed (``failure``, the gate of
/// "Restart cmux-tui" while no daemon runs, restore fuzz h2) and whether it failed the way a stuck
/// owner makes it fail (the automatic restart's input). The gate's transition is cmux-daemon-launch-core's
/// `note_outcome`. Shared by every copy of one launcher.
public final class EnsureOutcome: Sendable {
    /// The gate as the launch rules read and write it.
    struct Gate: Codable, Equatable {
        var ownerLooksStuck = false
        var failure: Failure?
        /// Ensures that failed in a row since the last one that worked.
        var failedInARow = 0

        struct Failure: Codable, Equatable { var kind: String, detail: String }
    }

    private struct State {
        var gate = Gate()
        var observer: (@MainActor @Sendable () -> Void)?
        /// Gets every ensure's outcome (the automatic restart, ``UnresponsiveOwnerWatch``).
        var watch: UnresponsiveOwnerWatch?
    }

    private let state = Mutex(State())

    public init() {}

    /// The last ensure failed as a stuck owner makes it fail; false after one that succeeded.
    public var ownerLooksStuck: Bool { state.withLock { $0.gate.ownerLooksStuck } }

    /// Why the last ensure failed; nil after one that succeeded (or before any ran).
    public var failure: DaemonStartFailure? {
        state.withLock { $0.gate.failure }.map { DaemonStartFailure(kind: .init(rawValue: $0.kind) ?? .failed, detail: $0.detail) }
    }

    /// How many ensures failed in a row since the last one that worked (0 after one that worked).
    public var failedInARow: Int { state.withLock { $0.gate.failedInARow } }

    /// Calls `observer` on the main actor after each change of ``ownerLooksStuck``, ``failure`` or
    /// ``failedInARow`` (so after every failed ensure).
    public func observe(_ observer: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.observer = observer }
    }

    /// Feeds every ensure's outcome to `watch`, which restarts an owner that stays stuck.
    public func follow(_ watch: UnresponsiveOwnerWatch) {
        state.withLock { $0.watch = watch }
    }

    /// Records how an ensure ended (nil: it succeeded, finding or starting the owner `pid`).
    /// `freeBytes`: the free space on the state's volume after a failure (nil: unknown).
    func note(_ error: (any Error)?, pid: Int32? = nil, freeBytes: UInt64? = nil) {
        struct Request: Encodable { var state: Gate, error: DaemonLaunchErrorInput?, pid: Int32?, freeBytes: UInt64? }
        struct Reply: Decodable { var state: Gate, changed: Bool, watch: UnresponsiveOwnerWatch.Ensure }
        let input = error.map(DaemonLaunchErrorInput.init)
        let (observer, watch, ensure) = state.withLock { state -> ((@MainActor @Sendable () -> Void)?, UnresponsiveOwnerWatch?, UnresponsiveOwnerWatch.Ensure) in
            let request = Request(state: state.gate, error: input, pid: pid, freeBytes: freeBytes)
            guard let reply = DaemonLaunchRules.call("note_outcome", request, as: Reply.self) else {
                // A library that does not answer still counts the failure, so Restart cmux-tui is offered.
                let failed = error != nil
                state.gate = Gate(ownerLooksStuck: false,
                                  failure: error.map { Gate.Failure(kind: "failed", detail: String(describing: $0)) },
                                  failedInARow: failed ? state.gate.failedInARow + 1 : 0)
                return (state.observer, state.watch, failed ? .failed : .ready(pid: pid))
            }
            state.gate = reply.state
            return (reply.changed ? state.observer : nil, state.watch, reply.watch)
        }
        watch?.note(ensure)
        guard let observer else { return }
        // task-owner: one main-actor hop per change; the observer reads the current value
        Task { @MainActor in observer() }
    }
}

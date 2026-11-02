public import CmuxNextControl

#if DEBUG || CMUX_BENCH_HOOKS
/// A test seam (DEBUG and bench builds only; a release router drops every `debug.*` method): holds the close warning's
/// daemon read (``DaemonService/closeReadStarts()``, before `DestructiveConfirmation.runningPrograms` asks the terminals)
/// until a test releases it, so a journey types inside that read in every round, on any host (P0 close-then-type: the
/// first key after Cmd-W went into the closing terminal while the read was open). No product timing: a build without
/// the debug methods has no hold, and an armed hold that nobody releases ends after ``limit``.
/// - `debug.close.hold {}`: from now on, every such read waits for the release. Answers `held` (0).
/// - `debug.close.release {}`: lets every waiting read go on and disarms the hold. Answers `resumed`: the reads that
///   really waited for this release (0: no close read ran since the hold).
///
/// One per daemon (``DaemonService/closeReadHold``); the app registers the local daemon's methods.
@MainActor
public final class DebugCloseReadHold {
    /// The longest a held read waits for its release.
    var limit: Duration = .seconds(30)

    private var armed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var round = 0

    /// How many close reads wait for the release now (a test waits for its read to be held before it releases).
    public var held: Int { waiting.count }

    /// Waits for the release when a hold is armed; returns at once otherwise.
    func readStarts() async {
        guard armed else { return }
        let limit = limit, round = round
        // task-owner: the hold's own bound; a release first makes it a no-op.
        Task { @MainActor [weak self] in
            // wakeup-allow: a DEBUG test seam's one-shot bound, so a hold nobody releases never keeps a close.
            try? await Task.sleep(for: limit)
            if self?.round == round { self?.release() }
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Arms the hold: every close read from now on waits for ``release()`` (tests; `debug.close.hold`).
    public func arm() {
        release()
        armed = true
    }

    /// Disarms the hold and lets every waiting read go on; returns how many waited.
    @discardableResult
    public func release() -> Int {
        armed = false
        round += 1
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
        return resumed.count
    }

    /// `debug.close.hold` and `debug.close.release`.
    public var methods: [ControlMethod] {
        [
            .mainActor("debug.close.hold") { [self] call in
                arm()
                var report = call.params.filter { _ in false }
                report["held"] = .number(0)
                return .value(.object(report))
            },
            .mainActor("debug.close.release") { [self] call in
                var report = call.params.filter { _ in false }
                report["resumed"] = .number(Double(release()))
                return .value(.object(report))
            },
        ]
    }
}
#endif

extension DaemonService {
    /// A close warning's read of the terminals starts: in DEBUG and bench builds a test may hold it there
    /// (`debug.close.hold`, ``DebugCloseReadHold``); in other builds it goes on at once.
    @MainActor public func closeReadStarts() async {
        #if DEBUG || CMUX_BENCH_HOOKS
        await closeReadHold.readStarts()
        #endif
    }
}

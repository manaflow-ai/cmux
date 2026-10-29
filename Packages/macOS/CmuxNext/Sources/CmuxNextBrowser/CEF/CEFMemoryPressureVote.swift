public import CmuxNextCompat
import CmuxNextSignposts

/// cmux's vote in Chromium's memory pressure aggregator: the memory coordinator's level
/// (``MemoryPressureVoteSource/pressureVote``) reaches the fork's `cmux_memory_pressure_vote`, one
/// `MemoryPressureVoter` that the fork makes with `MultiSourceMemoryPressureMonitor::CreateVoter`
/// (components/memory_pressure/multi_source_memory_pressure_monitor.h) next to the platform voter that
/// content/browser/browser_main_loop.cc `CreateMemoryPressureMonitor` starts. Chromium takes the highest
/// vote, so the debug override holds Chromium's level after a kernel normal event, and a vote of normal
/// (Chromium's `MEMORY_PRESSURE_LEVEL_NONE`) gives the level back to Chromium's platform voter. Nothing calls
/// Chromium's `NotifyMemoryPressure` directly.
///
/// One call per change of the vote, none for a repeated one. Chromium starts with no cmux voter, which is
/// the same as a vote of none: a vote of normal before any other makes no call. A vote made before
/// Chromium runs is sent once it is ready (``chromiumDidStart()``). On a fork without the call the shim
/// returns at once and nothing changes in Chromium.
///
/// Each call is one ``SignpostName/cefMemoryPressureVote`` interval on the main thread: the synchronous part
/// of the vote (in process, the sync listeners Chromium runs when the aggregate changes; in host library
/// mode, one post). Chromium's async listeners run later, in `cef.pump` slices or in the host process.
@MainActor
final class CEFMemoryPressureVote {
    /// Sends one vote (`base::MemoryPressureLevel`: 0 none, 1 moderate, 2 critical) to Chromium; false when
    /// Chromium does not run now (not started yet, or quit began), so the vote waits.
    typealias Send = @MainActor (_ level: Int32) -> Bool

    private let send: Send
    private let signposter: Signposter
    /// The vote of the source, sent or not.
    private(set) var wanted: MemoryPressureLevel = .normal
    /// The vote Chromium holds: normal until the first vote reaches it.
    private(set) var sent: MemoryPressureLevel = .normal
    private var observation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameters:
    ///   - signposter: Records each call's interval (``Signposter/cef`` in the app).
    ///   - send: Sends one vote to Chromium (`cmux_shim_memory_pressure_vote`).
    init(signposter: Signposter = .cef, send: @escaping Send) {
        self.signposter = signposter
        self.send = send
    }

    /// Votes `source`'s vote now and each change of it after, until ``follow(_:)`` is called again.
    func follow(_ source: any MemoryPressureVoteSource) {
        observation = source.observePressureVote { [weak self] vote in self?.vote(vote) }
        vote(source.pressureVote)
    }

    /// Takes a new vote and sends it when Chromium holds another.
    func vote(_ level: MemoryPressureLevel) {
        wanted = level
        sendIfChanged()
    }

    /// A Chromium that just started has no cmux voter: the vote made so far goes to it now, unless it is none.
    func chromiumDidStart() {
        sent = .normal
        sendIfChanged()
    }

    private func sendIfChanged() {
        guard wanted != sent else { return }
        let level = Self.chromiumLevel(wanted)
        let interval = signposter.begin(.cefMemoryPressureVote, "level=\(level)", arg0: UInt64(level))
        let isSent = send(level)
        signposter.end(.cefMemoryPressureVote, interval)
        if isSent { sent = wanted }
    }

    /// `level` as Chromium's `base::MemoryPressureLevel` (base/memory/memory_pressure_level.h): macOS warning
    /// is Chromium's moderate, as `SystemMemoryPressureEvaluatorMac` maps `DISPATCH_MEMORYPRESSURE_WARN`.
    nonisolated static func chromiumLevel(_ level: MemoryPressureLevel) -> Int32 {
        switch level {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

extension CEFMemoryPressureVote {
    /// `runtime`'s vote: each one goes to `cmux_shim_memory_pressure_vote` while Chromium is ready and quit has
    /// not begun; the shim's answer is not read, as the Chromium Host takes the vote as a one-way op.
    static func sending(to runtime: CEFRuntime) -> CEFMemoryPressureVote {
        CEFMemoryPressureVote { [weak runtime] level in
            guard let runtime, runtime.state == .ready, runtime.shutdownSequence == nil, let shim = runtime.shim else { return false }
            _ = shim.memoryPressureVote(level)
            return true
        }
    }
}

extension CEFEngine {
    /// The engine, whose Chromium takes `source`'s vote into its memory pressure aggregator from now on, next to
    /// Chromium's own platform voter (``CEFMemoryPressureVote``). A vote made before Chromium starts reaches it once
    /// it is ready. The process has one Chromium: the engine made last gives its source.
    ///
    /// - Parameter source: The app's memory coordinator (its level is the vote).
    /// - Returns: This engine.
    public func votingMemoryPressure(of source: any MemoryPressureVoteSource) -> CEFEngine {
        CEFRuntime.shared.memoryPressureVote.follow(source)
        return self
    }
}

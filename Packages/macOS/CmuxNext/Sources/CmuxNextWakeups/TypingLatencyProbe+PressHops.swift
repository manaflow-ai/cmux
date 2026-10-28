import CmuxNextCompat
import Foundation

/// The hops that name their press: Ghostty's write and the send, in a surface's input order; the echo
/// the daemon names and the chunk that carries it; the frame of a surface (``TypingLatencyProbe``).
extension TypingLatencyProbe {
    /// The flow for the daemon's next `send` request: the oldest press whose bytes Ghostty wrote
    /// (``inputWritten(on:)``) and that has not gone out. A session sends its input in the order
    /// Ghostty wrote it, so that press's bytes are the ones being sent. Set whenever the probe records,
    /// a CSV alone too, so the daemon's echo names its press. Nil while the probe is off, the
    /// keystroke-timing gate is closed or no written press waits.
    public var openFlow: UInt64? {
        guard isSampling else { return nil }
        return state.withLock { state -> UInt64? in
            state.open.first(where: { $0.has(.ioWrite) && !$0.has(.socketSubmit) })?.flow
        }
    }

    /// The key router handed the newest press to the terminal `surface` names: records its
    /// `app.key.terminal` hop (no CSV column has it), and that surface's write, output and frame hops
    /// may mark it from now on. `display` is the display of the terminal's window, where the echo is presented
    /// (``attach(presents:)``). Nothing while the probe is off or no press is open.
    public func keyReachedTerminal(_ surface: SurfaceKey, display: UInt32? = nil) {
        guard isSampling, let flow = state.withLock({ state -> UInt64? in
            guard let newest = state.newest else { return nil }
            state.open[newest].surface = surface
            state.open[newest].display = display
            return state.open[newest].flow
        }) else { return }
        if flowsStarted { emitHop(.appKeyTerminal, flow: flow) }
    }

    /// Ghostty took the press being dispatched (`ghostty_surface_key` returned true for a press or a
    /// repeat): its bytes are still to be written after its dispatch ends.
    public func terminalTookKey() {
        guard isSampling else { return }
        state.withLock { state in
            guard let newest = state.newest else { return }
            state.open[newest].tookByTerminal = true
        }
    }

    /// Ghostty's write callback ran for `surface` (its IO thread): the `io_write` hop of that surface's
    /// oldest press whose bytes were not written yet. Ghostty writes one surface's keys in the order it
    /// took them, so a key dispatched while an earlier one is still being written waits its turn.
    public func inputWritten(on surface: SurfaceKey) {
        guard isSampling else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = Thread.isMainThread
        let recorded = withState { state -> Recorded? in
            guard let index = state.open.firstIndex(where: { $0.awaitsWrite(on: surface) }) else { return nil }
            state.dropEchoSample(overtakenBy: index)
            return state.record(.ioWrite, at: index, now: now, onMain: onMain)
        }
        finish(recorded.map { [$0] } ?? [])
    }

    /// Records `mark` for the press `flow` names: its send (``Mark/socketSubmit``), and the session and
    /// the lane taking the output chunk its echo came in (``Mark/outputReceived``, ``Mark/outputParsed``).
    public func mark(_ mark: Mark, flow: UInt64) {
        guard isSampling else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let recorded = withState { state -> Recorded? in
            guard let index = state.open.firstIndex(where: { $0.flow == flow }) else { return nil }
            return state.record(mark, at: index, now: now, onMain: false)
        }
        finish(recorded.map { [$0] } ?? [])
    }

    /// The attach reader decoded an `output` event. One that names its press (`flow`)
    /// marks that press's decode, and from then on an output that names none is
    /// not taken for an echo. Before that (a daemon without exact flows) the newest press sent and not
    /// decoded takes it, and older such presses are written unfinished: their echoes can no longer be
    /// told apart, and a press that got none (a password prompt) must not take a later key's.
    public func outputDecoded(flow: UInt64?) {
        guard isSampling else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let (recorded, dropped) = withState { state -> (Recorded?, [Sample]) in
            if let flow {
                state.exactEchoes = true
                guard let index = state.open.firstIndex(where: { $0.flow == flow }),
                      let recorded = state.record(.outputDecoded, at: index, now: now, onMain: false) else { return (nil, []) }
                state.open[index].exactEcho = true
                return (recorded, [])
            }
            guard !state.exactEchoes,
                  let index = state.open.lastIndex(where: { $0.has(.socketSubmit) && !$0.has(.outputDecoded) }),
                  let recorded = state.record(.outputDecoded, at: index, now: now, onMain: false) else { return (nil, []) }
            var dropped: [Sample] = []
            // Newest first, so each removal leaves the indices below it in place.
            for older in (0..<index).reversed() where state.open[older].has(.socketSubmit) && !state.open[older].has(.outputDecoded) {
                dropped.append(state.open.remove(at: older))
            }
            return (recorded, Array(dropped.reversed()))
        }
        finish(recorded.map { [$0] } ?? [])
        for sample in dropped { emit(sample, complete: false) }
    }

    /// Records `mark` for presses open on `surface`. ``Mark/contents`` (the surface's frame went to its
    /// layer) goes to every one whose echo was parsed: that frame shows it. ``Mark/outputReceived`` and
    /// ``Mark/outputParsed`` (the session took an output chunk, the lane parsed one) go only to presses
    /// whose echo named no press (a daemon without exact flows); a named echo's chunk marks its own press
    /// (``mark(_:flow:)``).
    ///
    /// - Parameters:
    ///   - awaitsGPU: The frame of a ``Mark/contents`` went to its layer before its GPU work finished: the
    ///     presents also wait for ``FramePresentEstimate/gpuDidFinish(flow:atNanos:)`` of each flow it closes.
    /// - Returns: The flows a ``Mark/contents`` closed, oldest first; empty for the other marks.
    @discardableResult
    public func mark(_ mark: Mark, surface: SurfaceKey, awaitsGPU: Bool = false) -> [UInt64] {
        guard isSampling else { return [] }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let recorded = withState { state -> [Recorded] in
            let commitsBefore = state.echoCommits.count
            defer {
                if awaitsGPU {
                    for index in commitsBefore..<state.echoCommits.count { state.echoCommits[index].awaitsGPU = true }
                }
            }
            var recorded: [Recorded] = []
            // Newest first: a press the frame closes leaves the indices below it in place.
            for index in state.open.indices.reversed() {
                let sample = state.open[index]
                guard sample.surface == surface, mark == .contents || !sample.exactEcho else { continue }
                if let one = state.record(mark, at: index, now: now, onMain: false) { recorded.append(one) }
            }
            return Array(recorded.reversed())
        }
        finish(recorded)
        return mark == .contents ? recorded.compactMap { $0.finished?.flow } : []
    }

    /// The oldest press open on `surface` whose echo was parsed: the frame Ghostty draws for `surface` now
    /// shows it (`ghostty.render`'s flow, ``GhosttyTraceHook``). Nil while none, the probe is off or the
    /// keystroke-timing gate is closed.
    public func echoFlow(on surface: SurfaceKey) -> UInt64? {
        guard isSampling else { return nil }
        return state.withLock { state in
            state.open.first(where: { $0.surface == surface && $0.has(.outputParsed) })?.flow
        }
    }
}

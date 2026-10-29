import CmuxNextCompat
import CmuxNextMetrics

/// The field histogram `key.echo_frame.<route>` (``HistogramID/keyEchoFrame(_:)``), from the
/// probe's own samples with no CSV, no key flows and no swizzle.
///
/// While no echo sample is open, every ``echoSampleInterval``th key-down opens one, and the probe records as it
/// does for a CSV until that press closes. The sample is the time from the key-down (the event's timestamp) to the
/// ``Mark/contents`` of the frame that shows its echo; that mark comes from the Ghostty trace hook's IOSurface
/// handoff, which turns sampling on (``startEchoSampling()``) only when the linked
/// libghostty has the hook, and stays installed while it is on. The route is the
/// press's surface's (``SurfaceKey/route``). Chrome's latency UKM samples its events the same way, a set kept by a
/// sampling controller rather than every one (cc/metrics/latency_ukm_reporter.cc).
///
/// With echo sampling off a key-down is one load; with it on, a key between samples adds a counter add. A press
/// that cannot show an echo (``Sample/showsNoEcho``) closes at its turn's commit, so a key typed into a text view
/// holds no sample open, and a press that never gets its echo goes out with the oldest past ``openCapacity``. When
/// the sample closes and nothing else records, the presses opened beside it are dropped and the probe is off again.
///
/// An output is taken for the sample's echo only while it can still be its own: the daemon names the press its next
/// PTY read follows, with no time limit (cmux-tui-core `InputFlowSlot`), so a key that echoed nothing would take the
/// next unrelated redraw. The sample is dropped, its press recorded nothing, when its echo is decoded more than
/// ``echoMaxAgeNanos`` after the key-down, or when a newer press on its surface is written before that: the newer
/// press then holds the daemon's slot, and an output without a flow goes to the newest press sent.
extension TypingLatencyProbe {
    /// One key-down in this many, counted while no echo sample is open, opens a `key.echo_frame` sample.
    public static let echoSampleInterval: UInt32 = 16

    /// An echo decoded later than this after its key-down is not taken for the sample's: 1 s.
    static let echoMaxAgeNanos: UInt64 = 1_000_000_000

    /// The bits of ``modes``.
    enum Modes {
        /// Key flows are on (``startFlows()``).
        static let flows: UInt8 = 1 << 0
        /// Echo sampling is on (``startEchoSampling()``).
        static let echoSampling: UInt8 = 1 << 1
        /// The echo sample is open: set and cleared under the state lock (``withState(_:)``).
        static let echoOpen: UInt8 = 1 << 2
        /// The bits that make the probe record.
        static let recording: UInt8 = flows | echoOpen
    }

    /// Whether echo sampling is on, so the frames' contents marks are needed even while no press is open
    /// (``GhosttyTraceHook``'s demand).
    public var samplesEchoFrames: Bool { modes.load(ordering: .relaxed) & Modes.echoSampling != 0 }

    /// Turns echo sampling on, for a probe made with `echoFrames`. The owner of the frames' contents marks calls
    /// it (the Ghostty trace hook, when the linked libghostty has one): with no mark a sample could never end.
    public func startEchoSampling() {
        guard echoMetrics != nil else { return }
        setModes(Modes.echoSampling, on: true)
        observeCommits()
    }

    /// Sets or clears `bits` of ``modes``.
    ///
    /// - Returns: ``modes`` as it was just before this change, so a caller sees whether its bits changed.
    @discardableResult
    func setModes(_ bits: UInt8, on: Bool) -> UInt8 {
        var current = modes.load(ordering: .relaxed)
        var exchanged = false
        // wakeup-allow: bounded: a compare-exchange retry; it loops only when another writer moved the word first.
        repeat {
            let desired = on ? current | bits : current & ~bits
            let result = modes.compareExchange(expected: current, desired: desired, ordering: .relaxed)
            exchanged = result.exchanged
            current = result.original
        } while !exchanged
        return current
    }

    /// Whether the key-down being opened is the echo sampler's: echo sampling is on, no echo sample is open, this
    /// is the ``echoSampleInterval``th key counted, and a metrics store takes the sample.
    ///
    /// - Parameter current: ``modes``, as the key-down read it.
    func echoSampleDue(_ current: UInt8) -> Bool {
        guard current & (Modes.echoSampling | Modes.echoOpen) == Modes.echoSampling, let echoMetrics,
              echoKeys.wrappingAdd(1, ordering: .relaxed).newValue % Self.echoSampleInterval == 0 else { return false }
        return MetricsStore.attached(to: echoMetrics.runtime) != nil
    }

    /// Records the echo sample's `key.echo_frame` from its key-down to its echo's frame.
    func recordEchoFrame(_ sample: Sample, micros: Int64) {
        echoMetrics?.record(.keyEchoFrame(sample.surface?.route ?? .local), micros)
    }

    /// Runs `body` on the state under its lock, then keeps ``Modes/echoOpen`` in step with it. When the echo
    /// sample closed and nothing else records, the presses opened beside it go too: no hop of theirs is read
    /// while the probe is off.
    func withState<Output: Sendable>(_ body: (inout State) -> Output) -> Output {
        state.withLock { state in
            let wasOpen = state.echoSampleOpen
            let result = body(&state)
            let isOpen = state.echoSampleOpen
            if isOpen != wasOpen {
                setModes(Modes.echoOpen, on: isOpen)
                if !isOpen, !writesCSV, !flowsStarted {
                    state.open.removeAll()
                    state.echoCommits.removeAll()
                }
            }
            return result
        }
    }
}

extension TypingLatencyProbe.State {
    /// Drops the echo sample when the press at `written` was just written on its surface before the sample's echo was
    /// decoded: from now on the next output is the newer press's.
    mutating func dropEchoSample(overtakenBy written: Int) {
        guard let surface = open[written].surface, let index = open.firstIndex(where: \.echoSampled), index < written,
              open[index].surface == surface, !open[index].has(.outputDecoded) else { return }
        open[index].echoSampled = false
    }
}

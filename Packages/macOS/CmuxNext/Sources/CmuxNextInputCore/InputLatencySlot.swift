/// One input's latency record: what it was, where it went, and the `CLOCK_UPTIME_RAW` nanoseconds
/// of each ``InputStage`` it passed (0 = skipped). Chromium's `EventMetrics` as a value
/// (cc/metrics/event_metrics.h): dispatch stage timestamps, `caused_frame_update`, and the
/// coalesced count of `ui/latency/latency_info.h`.
///
/// A plain fixed-size value (`_isPOD`): copying it into ``InputLatencyRing`` and a batch is a
/// memory copy, with no reference counting and no allocation.
public struct InputLatencySlot: Sendable, Equatable {
    public var kind: InputEventKind
    public var target: InputTarget
    public var entrypoint: InputEntrypoint
    public var presentationSource: InputPresentationSource
    /// The input changed a layer or its contents before the presented frame (Chrome
    /// `caused_frame_update`). The ledger drops non-key slots without one.
    public var causedFrameUpdate: Bool
    /// The display that showed the frame has a variable refresh rate (ProMotion, adaptive
    /// sync): its rows are labelled, since a vsync estimate drifts there.
    public var isVariableRefresh: Bool
    /// How many OS events the slot covers (1 unless the input was coalesced).
    public var coalescedCount: UInt16
    /// The virtual key code of a key slot (`NSEvent.keyCode`), 0 for other kinds: pairs a key press
    /// with its release into one interaction (``InteractionLatency``). Never leaves the Mac.
    public var keyCode: UInt16

    public var generated: UInt64
    public var lastGenerated: UInt64
    public var arrivedMain: UInt64
    public var dispatchStart: UInt64
    public var textInputStart: UInt64
    public var textInputEnd: UInt64
    public var dispatchEnd: UInt64
    public var mainCommit: UInt64
    public var contentSubmitted: UInt64
    public var daemonReceived: UInt64
    public var ptyWritten: UInt64
    public var echoRead: UInt64
    public var echoSent: UInt64
    public var presented: UInt64
    public var echoParsed: UInt64

    /// A slot with every stage skipped.
    public init(
        kind: InputEventKind,
        target: InputTarget,
        entrypoint: InputEntrypoint,
        presentationSource: InputPresentationSource = .estimatedVsync,
        causedFrameUpdate: Bool = false,
        isVariableRefresh: Bool = false,
        coalescedCount: UInt16 = 1,
        keyCode: UInt16 = 0
    ) {
        self.kind = kind
        self.target = target
        self.entrypoint = entrypoint
        self.presentationSource = presentationSource
        self.causedFrameUpdate = causedFrameUpdate
        self.isVariableRefresh = isVariableRefresh
        self.coalescedCount = coalescedCount
        self.keyCode = keyCode
        generated = 0
        lastGenerated = 0
        arrivedMain = 0
        dispatchStart = 0
        textInputStart = 0
        textInputEnd = 0
        dispatchEnd = 0
        mainCommit = 0
        contentSubmitted = 0
        daemonReceived = 0
        ptyWritten = 0
        echoRead = 0
        echoSent = 0
        presented = 0
        echoParsed = 0
    }

    /// The nanoseconds of `stage`, 0 when the input skipped it.
    public subscript(stage: InputStage) -> UInt64 {
        get {
            switch stage {
            case .generated: generated
            case .lastGenerated: lastGenerated
            case .arrivedMain: arrivedMain
            case .dispatchStart: dispatchStart
            case .textInputStart: textInputStart
            case .textInputEnd: textInputEnd
            case .dispatchEnd: dispatchEnd
            case .mainCommit: mainCommit
            case .contentSubmitted: contentSubmitted
            case .daemonReceived: daemonReceived
            case .ptyWritten: ptyWritten
            case .echoRead: echoRead
            case .echoSent: echoSent
            case .presented: presented
            case .echoParsed: echoParsed
            }
        }
        set {
            switch stage {
            case .generated: generated = newValue
            case .lastGenerated: lastGenerated = newValue
            case .arrivedMain: arrivedMain = newValue
            case .dispatchStart: dispatchStart = newValue
            case .textInputStart: textInputStart = newValue
            case .textInputEnd: textInputEnd = newValue
            case .dispatchEnd: dispatchEnd = newValue
            case .mainCommit: mainCommit = newValue
            case .contentSubmitted: contentSubmitted = newValue
            case .daemonReceived: daemonReceived = newValue
            case .ptyWritten: ptyWritten = newValue
            case .echoRead: echoRead = newValue
            case .echoSent: echoSent = newValue
            case .presented: presented = newValue
            case .echoParsed: echoParsed = newValue
            }
        }
    }

    /// Whether the input passed `stage`.
    public func reached(_ stage: InputStage) -> Bool {
        self[stage] != 0
    }

    /// Nanoseconds from the oldest OS event to the presented frame (Chrome
    /// `EventLatency.<Type>.TotalLatency`), or nil when either end was skipped.
    public var totalNanos: UInt64? {
        nanos(from: .generated, to: .presented)
    }

    /// Nanoseconds from `start` to `end`, or nil when either was skipped. A clock that ran
    /// backwards between two threads gives 0, not a wrapped value.
    public func nanos(from start: InputStage, to end: InputStage) -> UInt64? {
        let from = self[start]
        let to = self[end]
        guard from != 0, to != 0 else { return nil }
        return to > from ? to - from : 0
    }
}

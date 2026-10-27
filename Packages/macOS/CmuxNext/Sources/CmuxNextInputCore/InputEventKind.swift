/// What a person did, as one input latency slot records it (Chromium's `EventMetrics` event type,
/// cc/metrics/event_metrics.h, `EventType`). A scroll's first update after its begin is its own
/// kind, as Chrome reports `FirstGestureScrollUpdate` apart from later updates.
public enum InputEventKind: UInt8, Sendable, Hashable, CaseIterable {
    case keyPress
    case keyRelease
    case flags
    case mousePress
    case mouseRelease
    case pointerMove
    case drag
    case scrollBegin
    case scrollFirstUpdate
    case scrollUpdate
    case scrollMomentum
    case scrollEnd
    case magnify

    /// A key event: kept by the ledger even when it caused no frame update (Chrome keeps
    /// `EventLatency.KeyPressed` for keys that change nothing on screen).
    public var isKey: Bool {
        self == .keyPress || self == .keyRelease
    }
}

/// The view an input landed in, so each surface gets its own latency rows.
public enum InputTarget: UInt8, Sendable, Hashable, CaseIterable {
    case terminal
    case textView
    case chromiumPage
    case webkitPage
    case agentPane
    case layout
    case sidebar
    case palette
    case other
}

/// Where an input came from: a person's input, or a synthetic one (automation, scripts, replay)
/// that the person histograms leave out.
public enum InputEntrypoint: UInt8, Sendable, Hashable, CaseIterable {
    case person
    case automation
}

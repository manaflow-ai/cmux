/// One timestamp on an input's way from the OS event to the frame that shows it (Chromium's
/// `EventMetrics::DispatchStage`, cc/metrics/event_metrics.h). A stage a path does not take stays
/// 0 in the slot (skipped), as an empty `DispatchStage` slot in Chrome.
///
/// The raw value is the stage's position in ``InputLatencySlotTable``'s entry, so it never changes
/// once a build ships rows keyed by it; a new stage takes the next raw value.
public enum InputStage: UInt8, Sendable, Hashable, CaseIterable {
    /// The OS event time of the oldest event the slot covers (Chrome `kGenerated`).
    case generated
    /// The OS event time of the newest event a coalesced slot covers.
    case lastGenerated
    /// The event reached the app's main thread (`-[NSApplication sendEvent:]`).
    case arrivedMain
    /// The app started dispatching it to its target.
    case dispatchStart
    /// The text input system started handling it (`interpretKeyEvents`).
    case textInputStart
    /// The text input system finished.
    case textInputEnd
    /// Dispatch returned.
    case dispatchEnd
    /// The Core Animation commit after the dispatch ended.
    case mainCommit
    /// The target's content was submitted for display (a terminal frame, a page frame).
    case contentSubmitted
    /// The daemon received the input (terminal keys).
    case daemonReceived
    /// The daemon wrote it to the PTY.
    case ptyWritten
    /// The daemon read the program's echo from the PTY.
    case echoRead
    /// The daemon sent the echo to the app.
    case echoSent
    /// The frame that shows the input reached the display.
    case presented
    /// The app parsed the output that echoes a terminal key (its output lane): after
    /// ``echoSent`` and before ``contentSubmitted`` in time. Declared last, as a new stage takes the next raw
    /// value; readers order a slot's stages by time.
    case echoParsed
}

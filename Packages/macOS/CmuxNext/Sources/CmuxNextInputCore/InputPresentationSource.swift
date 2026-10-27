/// How a slot's ``InputStage/presented`` time was found (Chrome's presentation feedback flags,
/// ui/gfx/presentation_feedback.h: vsync estimate, hardware clock, hardware completion). The raw
/// value is stored in the slot table's meta word (3 bits), so a new case takes the next value.
public enum InputPresentationSource: UInt8, Sendable, Hashable, CaseIterable {
    /// The commit's vsync plus one render-server frame, the vsync read from the window's link
    /// tick after the commit (Chrome `kVSync`).
    case estimatedVsync
    /// A Metal drawable's presented time.
    case metalPresented
    /// A presentation time an out-of-process host reported (the Chromium helper).
    case hostFeedback
    /// A web page's own estimate (PerformanceEventTiming or a frame callback after the handler).
    case pageEstimated
    /// The commit's vsync extended from an older tick of the same display (no tick after the
    /// commit): the phase may have drifted, most on a variable-refresh display.
    case extrapolatedVsync
    /// No usable tick: the commit plus half a nominal refresh plus one frame.
    case nominalRefresh

    /// The time is an estimate from the commit, not a measured presentation.
    public var isEstimate: Bool {
        switch self {
        case .estimatedVsync, .extrapolatedVsync, .nominalRefresh: true
        case .metalPresented, .hostFeedback, .pageEstimated: false
        }
    }
}

/// How a slot's ``InputStage/presented`` time was found (Chrome's presentation feedback flags,
/// ui/gfx/presentation_feedback.h: vsync estimate, hardware clock, hardware completion).
public enum InputPresentationSource: UInt8, Sendable, Hashable, CaseIterable {
    /// The commit's vsync plus one render-server frame.
    case estimatedVsync
    /// A Metal drawable's presented time.
    case metalPresented
    /// A presentation time an out-of-process host reported (the Chromium helper).
    case hostFeedback
    /// A web page's own estimate (PerformanceEventTiming or a frame callback after the handler).
    case pageEstimated
}

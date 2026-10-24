public import Foundation

/// Times each scroll event the app dispatches to the frame that shows it (``SignpostName/scrollToFrame``).
///
/// The app's one input dispatch context (`InputDispatchContext`) calls ``begin(phase:eventTimestamp:)`` when a
/// scroll event's dispatch starts and calls the returned end with who took it when the dispatch ends. The App
/// passes ``ScrollFrameSignpost``; tests pass a recorder; ``NoScrollFrameTiming`` records nothing.
///
/// ```swift
/// let end = timing.begin(phase: .changed, eventTimestamp: event.timestamp)
/// end(.layout)
/// ```
@MainActor
public protocol ScrollFrameTiming {
    /// Starts timing one scroll event whose dispatch begins now.
    ///
    /// - Parameters:
    ///   - phase: Which part of a scroll the event is.
    ///   - eventTimestamp: The event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 when unknown.
    /// - Returns: The end, called once when the dispatch ends with who took the event.
    func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) -> @MainActor (ScrollFrameTarget) -> Void
}

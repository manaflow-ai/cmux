public import Foundation

/// Times each scroll event the app dispatches to the frame that shows it (``SignpostName/scrollToFrame``).
///
/// The app's one input dispatch context (`InputDispatchContext`) calls ``begin(phase:eventTimestamp:)`` when a
/// scroll event's dispatch starts and ``end(target:)`` with who took it when that dispatch ends. Dispatches nest (a
/// synthetic scroll sent from inside another dispatch), so each end closes the most recent timing still open: last
/// in, first out. No closure is handed out per event: this runs on every scroll event, about 120 a second on a
/// trackpad. The App passes ``ScrollFrameSignpost``; tests pass a recorder; ``NoScrollFrameTiming`` records nothing.
///
/// ```swift
/// timing.begin(phase: .changed, eventTimestamp: event.timestamp)
/// // ... the dispatch ...
/// timing.end(target: .layout)
/// ```
@MainActor
public protocol ScrollFrameTiming {
    /// Starts timing one scroll event whose dispatch begins now.
    ///
    /// - Parameters:
    ///   - phase: Which part of a scroll the event is.
    ///   - eventTimestamp: The event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 when unknown.
    func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval)

    /// Ends the most recent timing still open, the scroll event whose dispatch ends now.
    ///
    /// - Parameter target: Who took the event.
    func end(target: ScrollFrameTarget)
}

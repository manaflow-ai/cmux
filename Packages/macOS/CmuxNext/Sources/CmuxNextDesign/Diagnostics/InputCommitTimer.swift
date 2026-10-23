public import AppKit

/// `debug.input_commit`: for any key or click, the time from the input event to the Core Animation
/// commit of the transaction its dispatch left open (``SwitchFrameTimer``): `input_ms` is the
/// event's age when its dispatch began, `apply_ms` the dispatch itself (the work on the input's
/// turn), `commit_ms` the commit. One row per input, its kind the event (`keyDown`, `mouseDown`,
/// `mouseUp`), and `workspace_shown` the ``noteShown()`` calls during the dispatch (the app calls it
/// for each workspace content it shows: a space switch that shows its workspace in the key's own
/// turn shows 1). It times what no switch-specific timer covers (a space switch, a group collapse);
/// work an input defers past its turn is not in it.
@MainActor
public final class InputCommitTimer {
    /// The timer whose samples the socket method returns.
    public let timer: SwitchFrameTimer
    /// ``noteShown()`` calls since launch, recording or not.
    public private(set) var shows = 0

    /// - Parameter owner: The frame client's owner name (`debug.input_commit`).
    public init(owner: String) {
        timer = SwitchFrameTimer(owner: owner)
    }

    /// The app showed a workspace content (`WindowController.show`).
    public func noteShown() { shows &+= 1 }

    /// Times `body`, the dispatch of `event` whose result `window` commits, when recording.
    public func dispatching<T>(_ event: NSEvent, in window: NSWindow?, _ body: () -> T) -> T {
        let kind: String? = switch event.type {
        case .keyDown: "keyDown"
        case .leftMouseDown: "mouseDown"
        case .leftMouseUp: "mouseUp"
        default: nil
        }
        guard timer.isRecording, let kind else { return body() }
        timer.began("input", inputTimestamp: event.timestamp)
        timer.setKind("input", kind)
        let before = shows
        let result = body()
        timer.shown("input", in: window, extra: ["workspace_shown": Double(shows &- before)])
        return result
    }
}

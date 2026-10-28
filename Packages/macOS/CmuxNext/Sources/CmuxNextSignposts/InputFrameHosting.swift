/// A window that carries the app's one ``InputFrameSignpost``, so a view in it that commits input method text stamps
/// `input.frame.ime_commit` where it happens (the terminal's `insertText`), read when it is called.
///
/// ```swift
/// (window as? InputFrameHosting)?.inputFrames?.textCommitted(.imeCommit, eventTimestamp: 0)
/// ```
@MainActor
public protocol InputFrameHosting: AnyObject {
    /// The app's input-frame stamps; nil outside the app (tests, a window with no app).
    var inputFrames: InputFrameSignpost? { get }
}

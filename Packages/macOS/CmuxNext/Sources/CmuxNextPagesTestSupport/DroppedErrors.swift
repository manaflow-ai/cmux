public import CmuxNextErrorJournal

/// An ``ErrorRecording`` that keeps nothing, for a test page or pane whose errors the test does
/// not check. (The app passes its one journal; there is no default.)
public nonisolated struct DroppedErrors: ErrorRecording {
    /// Makes the recorder.
    public init() {}

    /// Drops `event`.
    public func record(_ event: ErrorEvent) async {}
}

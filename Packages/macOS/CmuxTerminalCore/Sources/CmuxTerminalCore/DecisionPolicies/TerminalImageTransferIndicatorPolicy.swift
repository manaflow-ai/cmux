/// Pure operation-identity gating for a terminal surface's image-transfer
/// indicator (the transient drag-and-drop progress spinner).
///
/// This is the terminal-domain home of the decision guards that lived inside
/// `GhosttyNSView.beginImageTransferIndicator`, `endImageTransferIndicator`,
/// and `handleImageTransferCancel`. The witness keeps every live side effect:
/// the main-thread hops, the `activeImageTransferOperation`/
/// `activeImageTransferCancelHandler`/`imageTransferIndicatorShowWorkItem`
/// stored state, the `NSProgressIndicator` spinner, the container `NSView`, and
/// the `DispatchWorkItem` delay timer. It resolves the live operation-identity
/// conditions (whether the scheduled operation is still the active one, whether
/// it was cancelled, whether an end request targets the active operation) to
/// plain `Bool`s and asks this type only whether to proceed, so the decisions
/// stay deterministic, testable value computations that reference no AppKit and
/// hold no reference to the app-target `TerminalImageTransferOperation`.
public enum TerminalImageTransferIndicatorPolicy: Sendable {
    /// Whether the delayed "reveal the spinner" work item should still run.
    ///
    /// The witness schedules a `DispatchWorkItem` 0.15s after a transfer begins.
    /// When it fires, the spinner is only shown if the operation it was
    /// scheduled for is still the active operation and has not been cancelled in
    /// the meantime.
    ///
    /// - `operationIsStillActive`: whether the scheduled operation is identical
    ///   (`===`) to the currently active operation.
    /// - `operationIsCancelled`: the operation's live `isCancelled` flag.
    public static func shouldShowAfterDelay(
        operationIsStillActive: Bool,
        operationIsCancelled: Bool
    ) -> Bool {
        operationIsStillActive && !operationIsCancelled
    }

    /// Whether an end request should proceed to tear down the indicator.
    ///
    /// A nil requested operation always ends (a blanket teardown). A specific
    /// requested operation only ends when it is the currently active operation,
    /// so a stale end request for a superseded transfer is ignored.
    ///
    /// - `hasRequestedOperation`: whether the end request named a specific
    ///   operation (`operation != nil`).
    /// - `requestedMatchesActive`: whether the requested operation is identical
    ///   (`===`) to the currently active operation.
    public static func shouldEnd(
        hasRequestedOperation: Bool,
        requestedMatchesActive: Bool
    ) -> Bool {
        !hasRequestedOperation || requestedMatchesActive
    }
}

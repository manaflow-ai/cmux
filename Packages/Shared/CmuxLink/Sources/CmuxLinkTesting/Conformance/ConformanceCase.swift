/// The behaviors every carrier must keep under `LinkSession`.
public enum ConformanceCase: String, Sendable, CaseIterable, Hashable {
    /// Reliable messages arrive once and in order, both directions.
    case ordering
    /// Messages in flight when the transport dies arrive after reconnect.
    case lossRecovery
    /// The session resumes with its cursors; stale cursors report a gap.
    case reconnectResume
    /// A consumer that stops reading suspends the remote sender at its budget.
    case backPressure
    /// Channel close delivers prior data first; session close ends everything.
    case closeSemantics
    /// A path change keeps the stream and updates the badge; roam reconnects.
    case pathChangeMidStream
    /// Input overtakes queued bulk.
    case priority
}

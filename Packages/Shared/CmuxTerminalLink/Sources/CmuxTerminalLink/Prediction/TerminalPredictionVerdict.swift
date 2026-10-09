/// What a host `bytes` frame did to the outstanding predictions.
public enum TerminalPredictionVerdict: Hashable, Sendable {
    /// Nothing was outstanding over this frame's range.
    case none
    /// This many predicted bytes matched the host's echo.
    case confirmed(Int)
    /// A shown prediction disagrees with the host: restore from a READY.
    case rollback
}

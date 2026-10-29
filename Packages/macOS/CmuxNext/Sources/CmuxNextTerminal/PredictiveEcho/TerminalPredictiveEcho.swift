/// How a terminal session predicts its echo (`terminal.predictiveEcho`). The App's
/// session delegate gives the ``Mode`` (``TerminalSessionDelegate/terminalSessionPredictiveEcho(_:)``);
/// none, the setting's `off`, makes no prediction engine at all.
public nonisolated struct TerminalPredictiveEcho: Equatable, Sendable {
    public nonisolated enum Mode: Equatable, Sendable {
        /// For a remote session, when the measured echo is slow, and after a stalled echo.
        case remote
        /// Whenever an echo confirmed the predictions.
        case always

        /// The setting's value (`remote`, `always`); nil for `off` or anything else.
        public init?(setting: String) {
            switch setting {
            case "remote": self = .remote
            case "always": self = .always
            default: return nil
            }
        }
    }

    public var mode: Mode
    /// The terminal runs on another machine (a Cloud machine or another Mac's daemon).
    public var isRemoteSession: Bool

    public init(mode: Mode, isRemoteSession: Bool) {
        self.mode = mode
        self.isRemoteSession = isRemoteSession
    }

    /// The engine's mode.
    var engineMode: PredictiveEcho.Mode {
        switch mode {
        case .remote: .remote
        case .always: .always
        }
    }
}

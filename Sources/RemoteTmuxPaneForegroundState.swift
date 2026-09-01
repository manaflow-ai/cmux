import CmuxTmuxControlMode

/// Compatibility name for the remote mirror. The classifier itself lives in
/// the shared control-mode package so direct Harbor panes and mirrored panes
/// cannot acquire different resize or close policies.
typealias RemoteTmuxPaneForegroundState = TmuxPaneForegroundState

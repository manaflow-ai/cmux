import CmuxTerminalCore

extension SessionPanelSnapshot {
    /// Old snapshots may contain raw OSC transcripts. Custom names are restored
    /// separately; even when `title` duplicated that name, the automatic fallback
    /// must be bounded before it enters workspace or Dock state.
    var automaticTitleForRestore: String? {
        guard type == .terminal else { return title }
        return title.flatMap { AutomaticTerminalTitle($0)?.value }
    }
}

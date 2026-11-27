import Foundation

/// Where a remote-tmux mirror's new tab (a tmux window) should be inserted.
enum RemoteTmuxMirrorNewTabPlacement: Equatable {
    /// Append after the last window (`newTabPosition: .end`).
    case end

    /// Insert right after the window backing `panelId`.
    ///
    /// Used for `newTabPosition: .current` and targeted entrypoints such as
    /// "new terminal to right". Falls back to `.end` when the panel has no live
    /// window so a new tab is never dropped.
    case afterPanel(UUID)
}

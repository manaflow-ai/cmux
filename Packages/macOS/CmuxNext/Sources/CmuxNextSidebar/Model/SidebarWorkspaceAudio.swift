public import Foundation

/// The sound of a workspace's tabs, as its sidebar row shows it: a small
/// speaker while any tab plays sound, crossed out while its tabs are muted.
/// A click on the speaker mutes the playing tabs, or unmutes the muted ones
/// (`SidebarIntent.toggleWorkspaceAudio`).
public nonisolated enum SidebarWorkspaceAudio: Hashable, Sendable {
    /// At least one tab plays sound.
    case playing
    /// No tab plays sound, and at least one is muted.
    case muted

    /// The row's speaker for its tabs' speakers (`nil`: the tab is silent):
    /// playing when any tab plays sound, else muted when any tab is muted,
    /// else none.
    public static func merge(_ tabs: some Sequence<SidebarWorkspaceAudio?>) -> SidebarWorkspaceAudio? {
        var muted = false
        for tab in tabs {
            if tab == .playing { return .playing }
            if tab == .muted { muted = true }
        }
        return muted ? .muted : nil
    }

    /// What a click on a row showing `self` does to one of its tabs, whose
    /// own speaker is `tab`: `true` mutes it, `false` unmutes it, `nil`
    /// leaves it. A playing row mutes its playing tabs; a muted row unmutes
    /// its muted tabs.
    public func change(for tab: SidebarWorkspaceAudio?) -> Bool? {
        switch self {
        case .playing: tab == .playing ? true : nil
        case .muted: tab == .muted ? false : nil
        }
    }
}

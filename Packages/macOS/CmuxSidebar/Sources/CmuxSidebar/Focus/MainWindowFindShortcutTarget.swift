/// The surface the Find shortcut should drive, computed from the current focus
/// owner and intent.
public enum MainWindowFindShortcutTarget: Equatable {
    /// Find should open in the main panel.
    case mainPanelFind
    /// Find should open the right sidebar's file search.
    case rightSidebarFileSearch
    /// Find has no applicable target.
    case none
}

extension MainWindowFindShortcutTarget {
    /// The Find target when the right sidebar is showing `mode`: the file search
    /// for the files mode, otherwise no right-sidebar target.
    public static func forRightSidebarMode(_ mode: RightSidebarMode) -> MainWindowFindShortcutTarget {
        mode == .files ? .rightSidebarFileSearch : .none
    }
}

import AppKit

// Per-action policy predicates used by the shortcut dispatch chain when
// deciding whether stale menu-item key equivalents must be suppressed.
extension AppDelegate {
    func isMenuBackedShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .showHideAllWindows
            && action != .globalSearch
            && action != .clearScreenKeepScrollback
            && action != .toggleVoiceDictation
            && action != .fileExplorerOpenSelection
            && action != .fileExplorerOpenSelectionFinderAlias
    }

    func canCurrentShortcutPreventStaleMenuSuppression(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .fileExplorerOpenSelection && action != .fileExplorerOpenSelectionFinderAlias
    }

    func isCloseShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        switch action {
        case .closeTab, .closeWorkspace, .closeWindow:
            return true
        default:
            return false
        }
    }
}

import AppKit
import Foundation

/// A user-defined key table that temporarily routes bare keys to cmux actions.
///
/// Navigation modes are deliberately limited to cmux-owned navigation actions.
/// They cannot invoke shell commands, arbitrary configured actions, or actions
/// that mutate unrelated application state. A mode is entered by its explicit
/// `enter` binding and remains active until Escape, Return, or an unbound key.
struct KeyboardNavigationMode: Equatable {
    let id: String
    let enterShortcut: StoredShortcut
    let bindings: [StoredShortcut: KeyboardShortcutSettings.Action]
    let swallowUnboundKeys: Bool

    /// Parses one `shortcuts.modes` entry from the JSON-compatible object used
    /// by ``CmuxSettingsFileStore``. Invalid entries return nil so the caller
    /// can preserve valid sibling settings while reporting the bad mode.
    static func parse(id rawID: String, value: Any) -> KeyboardNavigationMode? {
        guard let section = value as? [String: Any] else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let rawEnter = section["enter"] as? String,
              let enterShortcut = StoredShortcut.parseConfig(rawEnter, allowBareFirstStroke: true),
              !enterShortcut.isUnbound,
              !enterShortcut.hasChord else {
            return nil
        }

        guard let rawBindings = section["bindings"] as? [String: Any] else { return nil }
        var bindings: [StoredShortcut: KeyboardShortcutSettings.Action] = [:]
        for (rawKey, rawAction) in rawBindings {
            guard let actionID = rawAction as? String,
                  let action = KeyboardShortcutSettings.Action(rawValue: actionID),
                  action.allowsKeyboardNavigationMode,
                  let shortcut = StoredShortcut.parseConfig(rawKey, allowBareFirstStroke: true),
                  !shortcut.isUnbound,
                  !shortcut.hasChord,
                  bindings[shortcut] == nil else {
                return nil
            }
            bindings[shortcut] = action
        }

        let swallowUnboundKeys: Bool
        if let rawValue = section["swallowUnboundKeys"] {
            guard let value = rawValue as? Bool else { return nil }
            swallowUnboundKeys = value
        } else {
            swallowUnboundKeys = false
        }

        return KeyboardNavigationMode(
            id: id,
            enterShortcut: enterShortcut,
            bindings: bindings,
            swallowUnboundKeys: swallowUnboundKeys
        )
    }

    func action(
        for event: NSEvent,
        matcher: ConfiguredShortcutMatcher
    ) -> KeyboardShortcutSettings.Action? {
        binding(for: event, matcher: matcher)?.action
    }

    func binding(
        for event: NSEvent,
        matcher: ConfiguredShortcutMatcher
    ) -> (shortcut: StoredShortcut, action: KeyboardShortcutSettings.Action)? {
        bindings
            .sorted { lhs, rhs in
                lhs.key.configIdentifier.localizedStandardCompare(rhs.key.configIdentifier) == .orderedAscending
            }
            .first { matcher.matches(event: event, shortcut: $0.key) }
            .map { (shortcut: $0.key, action: $0.value) }
    }
}

extension KeyboardShortcutSettings.Action {
    /// Actions that are safe and meaningful while a navigation mode owns the
    /// keyboard. Keep this allowlist explicit so new destructive or content
    /// actions cannot become mode-capable accidentally.
    var allowsKeyboardNavigationMode: Bool {
        switch self {
        case .focusRightSidebar,
             .nextSurface,
             .prevSurface,
             .nextSidebarTab,
             .prevSidebarTab,
             .nextSidebarTabInGroup,
             .prevSidebarTabInGroup,
             .moveWorkspaceUp,
             .moveWorkspaceDown,
             .focusHistoryBack,
             .focusHistoryForward,
             .focusHistoryLast,
             .selectWorkspaceByNumber,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .focusPreviousPane,
             .focusNextPane,
             .focusPaneByNumber,
             .splitRight,
             .splitDown,
             .newPaneAutoLayout,
             .toggleSplitZoom,
             .equalizeSplits,
             .resizePaneLeft,
             .resizePaneRight,
             .resizePaneUp,
             .resizePaneDown,
             .selectSurfaceByNumber,
             .moveSurfaceLeft,
             .moveSurfaceRight,
             .moveSurfaceToPreviousPane,
             .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft,
             .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp,
             .moveSurfaceToPaneDown,
             .toggleCanvasLayout,
             .canvasRevealFocusedPane,
             .canvasOverview,
             .canvasZoomIn,
             .canvasZoomOut,
             .canvasZoomReset,
             .canvasTidy,
             .canvasAlignLeft,
             .canvasAlignRight,
             .canvasAlignTop,
             .canvasAlignBottom,
             .canvasEqualizeWidths,
             .canvasEqualizeHeights,
             .canvasDistributeHorizontally,
             .canvasDistributeVertically:
            return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    static let keyboardNavigationModeDidChange = Notification.Name(
        "cmux.keyboardNavigationModeDidChange"
    )
}

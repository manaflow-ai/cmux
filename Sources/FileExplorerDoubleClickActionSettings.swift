import Foundation

/// What double-clicking (or activating via Return in the search results list) a
/// FILE in the file explorer / right-sidebar file tree should do.
///
/// Directories are unaffected — they always expand/collapse regardless of this
/// setting. The default, ``preview``, preserves the historical behavior of
/// opening the built-in cmux file preview, so existing users see no change.
enum FileExplorerDoubleClickAction: String, CaseIterable, Sendable {
    /// Open the built-in cmux file preview (historical default).
    case preview
    /// Open with the macOS default application for the file type — identical to
    /// the file explorer context menu's "Open in <App>" action.
    case defaultEditor
    /// Open with the user's configured `app.preferredEditor` command, matching
    /// the terminal Cmd-click path (`PreferredEditorService.open(_:)`). Falls
    /// back to ``defaultEditor`` when no preferred editor command is configured.
    case preferredEditor
}

/// The concrete open behavior for a file activation, after resolving the
/// configured action and any fallbacks. Computed by
/// ``FileExplorerDoubleClickActionSettings/fileActivation(action:hasPreferredEditorCommand:)``.
enum FileExplorerFileActivation: Equatable, Sendable {
    case preview
    case defaultEditor
    case preferredEditor
}

enum FileExplorerDoubleClickActionSettings {
    static let key = "fileExplorerDoubleClickAction"
    static let didChangeNotification = Notification.Name("cmux.fileExplorerDoubleClickActionDidChange")
    static let defaultValue: FileExplorerDoubleClickAction = .preview

    /// Parse a raw config/UserDefaults string into an action, falling back to
    /// ``defaultValue`` (`.preview`) for `nil` or unrecognized values.
    static func action(forRawValue raw: String?) -> FileExplorerDoubleClickAction {
        guard let raw, let action = FileExplorerDoubleClickAction(rawValue: raw) else {
            return defaultValue
        }
        return action
    }

    static func resolvedAction(defaults: UserDefaults = .standard) -> FileExplorerDoubleClickAction {
        action(forRawValue: defaults.string(forKey: key))
    }

    static func setAction(
        _ action: FileExplorerDoubleClickAction,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(action.rawValue, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    /// Resolve the concrete behavior for a FILE activation given the chosen
    /// action and whether a preferred-editor command is configured. Directories
    /// are handled by the caller and never reach this function.
    ///
    /// The `preferredEditor` action falls back to `defaultEditor` when no
    /// preferred-editor command is set, mirroring the terminal Cmd-click path's
    /// behavior of opening with the system default when `app.preferredEditor`
    /// is empty.
    static func fileActivation(
        action: FileExplorerDoubleClickAction,
        hasPreferredEditorCommand: Bool
    ) -> FileExplorerFileActivation {
        switch action {
        case .preview:
            return .preview
        case .defaultEditor:
            return .defaultEditor
        case .preferredEditor:
            return hasPreferredEditorCommand ? .preferredEditor : .defaultEditor
        }
    }
}

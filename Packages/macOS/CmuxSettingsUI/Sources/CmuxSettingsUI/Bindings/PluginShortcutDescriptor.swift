import CmuxSettings
import Foundation

/// A runtime-provided plugin command that can be edited in the shared
/// Keyboard Shortcuts section.
public struct PluginShortcutDescriptor: Identifiable, Equatable, Sendable {
    /// Stable, namespaced action id (`plugin.<plugin>.<action>`).
    public let id: String
    /// User-visible action title.
    public let title: String
    /// Optional plugin name/context shown beneath the title.
    public let subtitle: String?
    /// Effective persisted override or manifest default, or `nil` when unbound.
    public let shortcut: StoredShortcut?
    /// Display name of an action that conflicts with the current shortcut.
    public let conflictDisplayName: String?

    /// Creates a descriptor.
    public init(
        id: String,
        title: String,
        subtitle: String?,
        shortcut: StoredShortcut?,
        conflictDisplayName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.conflictDisplayName = conflictDisplayName
    }
}

/// Notification posted by a host when its plugin descriptor list changes.
public enum PluginShortcutSettings {
    /// Posted after plugin actions or their effective bindings change.
    public static let didChangeNotification = Notification.Name("cmux.pluginShortcutSettingsDidChange")
}

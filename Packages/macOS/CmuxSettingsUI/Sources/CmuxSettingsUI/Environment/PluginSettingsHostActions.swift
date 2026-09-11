import CmuxSettings

/// Host callbacks used by the plugin-management and plugin-shortcut settings.
@MainActor
public protocol PluginSettingsHostActions: AnyObject {
    /// Returns discovered plugins and their current approval state.
    func pluginManagementDescriptors() -> [PluginManagementDescriptor]

    /// Atomically approves all declared scopes and enables the reviewed plugin.
    func approveAndEnablePlugin(_ pluginID: String)

    /// Enables or disables a previously approved plugin.
    func setPluginEnabled(_ enabled: Bool, pluginID: String)

    /// Returns currently enabled plugin actions for the shared shortcut editor.
    func pluginShortcutDescriptors() -> [PluginShortcutDescriptor]

    /// Persists a dynamic plugin action shortcut; `.unbound` clears it.
    func setPluginShortcut(_ shortcut: StoredShortcut, actionID: String)

    /// Returns a conflicting action name, or `nil` when the binding is valid.
    func pluginShortcutConflict(_ shortcut: StoredShortcut, actionID: String) -> String?
}

public extension PluginSettingsHostActions {
    /// Default empty plugin management list for previews and test hosts.
    func pluginManagementDescriptors() -> [PluginManagementDescriptor] { [] }

    /// Default no-op approval for previews and test hosts.
    func approveAndEnablePlugin(_ pluginID: String) {}

    /// Default no-op enablement for previews and test hosts.
    func setPluginEnabled(_ enabled: Bool, pluginID: String) {}

    /// Default empty plugin list for previews and test hosts.
    func pluginShortcutDescriptors() -> [PluginShortcutDescriptor] { [] }

    /// Default no-op shortcut mutation for previews and test hosts.
    func setPluginShortcut(_ shortcut: StoredShortcut, actionID: String) {}

    /// Default conflict-free result for previews and test hosts.
    func pluginShortcutConflict(_ shortcut: StoredShortcut, actionID: String) -> String? { nil }
}

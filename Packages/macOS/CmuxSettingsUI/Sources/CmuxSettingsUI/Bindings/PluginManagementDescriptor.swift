import Foundation

/// A discovered plugin row shown in Automation settings.
public struct PluginManagementDescriptor: Identifiable, Equatable, Sendable {
    /// Stable plugin id.
    public let id: String
    /// Manifest display name.
    public let displayName: String
    /// Whether the plugin currently has an enabled grant.
    public let isEnabled: Bool
    /// Whether the user must review its requested scopes before enabling it.
    public let needsApproval: Bool
    /// Whether this row represents a validated plugin that can be toggled.
    public let canManage: Bool
    /// Human-readable capability declarations shown before approval.
    public let requestedCapabilities: [String]
    /// Load, launch, process-health, or management detail to surface in Settings.
    public let loadError: String?

    /// Creates a management descriptor.
    public init(
        id: String,
        displayName: String,
        isEnabled: Bool,
        needsApproval: Bool,
        canManage: Bool = true,
        requestedCapabilities: [String] = [],
        loadError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
        self.canManage = canManage
        self.requestedCapabilities = requestedCapabilities
        self.loadError = loadError
    }
}

/// Notifications emitted when the host's plugin management snapshot changes.
public enum PluginManagementSettings {
    /// Posted after discovery, approval, enablement, or process health changes.
    public static let didChangeNotification = Notification.Name("cmux.pluginRuntimeSnapshotDidChange")
}

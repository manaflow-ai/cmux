public import Foundation

/// Immutable metadata shown before an extension may execute.
public struct BrowserWebExtensionInstallPreview: Equatable, Identifiable, Sendable {
    /// Opaque identifier used to confirm or cancel this exact prepared install.
    public let id: UUID

    /// Extension-provided display name.
    public let name: String

    /// Extension-provided version.
    public let version: String

    /// Required named permissions declared by the manifest.
    public let requiredPermissions: [String]

    /// Required host match patterns declared by the manifest.
    public let requiredHosts: [String]

    /// Optional named permissions that can be granted later.
    public let optionalPermissions: [String]

    /// Optional host match patterns that can be granted later.
    public let optionalHosts: [String]

    /// Whether confirming replaces an existing logical extension.
    public let isUpdate: Bool

    /// Known capability limits that must be disclosed before confirmation.
    public let capabilityNotices: [BrowserWebExtensionCapabilityNotice]

    /// Creates a pre-activation install preview.
    public init(
        id: UUID,
        name: String,
        version: String,
        requiredPermissions: [String],
        requiredHosts: [String],
        optionalPermissions: [String],
        optionalHosts: [String],
        isUpdate: Bool,
        capabilityNotices: [BrowserWebExtensionCapabilityNotice] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.requiredPermissions = requiredPermissions.sorted()
        self.requiredHosts = requiredHosts.sorted()
        self.optionalPermissions = optionalPermissions.sorted()
        self.optionalHosts = optionalHosts.sorted()
        self.isUpdate = isUpdate
        self.capabilityNotices = capabilityNotices
    }
}

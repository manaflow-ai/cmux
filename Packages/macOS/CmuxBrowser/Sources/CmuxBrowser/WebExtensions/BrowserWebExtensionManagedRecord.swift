public import Foundation

/// The durable policy and source state for one explicitly approved extension.
public struct BrowserWebExtensionManagedRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable logical identity retained across catalog and Safari-app updates.
    public let id: String

    /// Extension-provided display name captured during permission review.
    public var displayName: String

    /// Extension version captured during the last approved install or update.
    public var version: String

    /// Durable package or signed-app source.
    public var source: BrowserWebExtensionManagedSource

    /// Whether WebKit should load the extension for this profile.
    public var isEnabled: Bool

    /// Whether the action icon is pinned to cmux's browser toolbar.
    public var isToolbarPinned: Bool

    /// Granted named permissions and their expiration dates.
    public var grantedPermissions: [String: Date]

    /// Required manifest permissions retained when optional access is revoked.
    public var requiredPermissions: [String]

    /// Denied named permissions and their expiration dates.
    public var deniedPermissions: [String: Date]

    /// Granted host match patterns and their expiration dates.
    public var grantedMatchPatterns: [String: Date]

    /// Required host patterns retained when optional access is revoked.
    public var requiredMatchPatterns: [String]

    /// Denied host match patterns and their expiration dates.
    public var deniedMatchPatterns: [String: Date]

    /// Whether the extension requested optional access to every host.
    public var hasRequestedOptionalAccessToAllHosts: Bool

    /// Product capability limits acknowledged during installation.
    public var capabilityNotices: [BrowserWebExtensionCapabilityNotice]

    /// Creates one durable management record.
    public init(
        id: String,
        displayName: String,
        version: String,
        source: BrowserWebExtensionManagedSource,
        isEnabled: Bool,
        isToolbarPinned: Bool = false,
        grantedPermissions: [String: Date],
        requiredPermissions: [String] = [],
        deniedPermissions: [String: Date] = [:],
        grantedMatchPatterns: [String: Date],
        requiredMatchPatterns: [String] = [],
        deniedMatchPatterns: [String: Date] = [:],
        hasRequestedOptionalAccessToAllHosts: Bool = false,
        capabilityNotices: [BrowserWebExtensionCapabilityNotice] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.source = source
        self.isEnabled = isEnabled
        self.isToolbarPinned = isToolbarPinned
        self.grantedPermissions = grantedPermissions
        self.requiredPermissions = requiredPermissions.sorted()
        self.deniedPermissions = deniedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.requiredMatchPatterns = requiredMatchPatterns.sorted()
        self.deniedMatchPatterns = deniedMatchPatterns
        self.hasRequestedOptionalAccessToAllHosts = hasRequestedOptionalAccessToAllHosts
        self.capabilityNotices = capabilityNotices
    }

    /// Creates a record whose permanent decisions do not expire.
    public init(
        id: String,
        displayName: String,
        version: String,
        source: BrowserWebExtensionManagedSource,
        isEnabled: Bool,
        isToolbarPinned: Bool = false,
        grantedPermissions: [String],
        requiredPermissions: [String]? = nil,
        deniedPermissions: [String] = [],
        grantedMatchPatterns: [String],
        requiredMatchPatterns: [String]? = nil,
        deniedMatchPatterns: [String] = [],
        hasRequestedOptionalAccessToAllHosts: Bool = false,
        capabilityNotices: [BrowserWebExtensionCapabilityNotice] = []
    ) {
        let expiration = Date.distantFuture
        self.init(
            id: id,
            displayName: displayName,
            version: version,
            source: source,
            isEnabled: isEnabled,
            isToolbarPinned: isToolbarPinned,
            grantedPermissions: Dictionary(uniqueKeysWithValues: grantedPermissions.map { ($0, expiration) }),
            requiredPermissions: requiredPermissions ?? grantedPermissions,
            deniedPermissions: Dictionary(uniqueKeysWithValues: deniedPermissions.map { ($0, expiration) }),
            grantedMatchPatterns: Dictionary(uniqueKeysWithValues: grantedMatchPatterns.map { ($0, expiration) }),
            requiredMatchPatterns: requiredMatchPatterns ?? grantedMatchPatterns,
            deniedMatchPatterns: Dictionary(uniqueKeysWithValues: deniedMatchPatterns.map { ($0, expiration) }),
            hasRequestedOptionalAccessToAllHosts: hasRequestedOptionalAccessToAllHosts,
            capabilityNotices: capabilityNotices
        )
    }
}

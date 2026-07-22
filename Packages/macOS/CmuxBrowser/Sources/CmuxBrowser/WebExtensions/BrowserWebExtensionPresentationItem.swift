public import Foundation

/// A value snapshot for one installed extension and its toolbar action.
public struct BrowserWebExtensionPresentationItem: Identifiable, Equatable, Sendable {
    /// The stable WebKit context identifier.
    public let id: String

    /// Stable management identity retained across package updates.
    public let managementID: String?

    /// The extension-provided display name.
    public let name: String

    /// The installed extension version.
    public let version: String

    /// Whether this extension is enabled for the profile.
    public let isEnabled: Bool

    /// Whether the manifest declares an action surface.
    public let hasAction: Bool

    /// Whether the action is pinned to the browser toolbar.
    public let isToolbarPinned: Bool

    /// Whether the action can run for the associated tab.
    public let isActionEnabled: Bool

    /// Whether a user click is waiting for WebKit's popup-ready callback.
    public let isAwaitingPopup: Bool

    /// A recoverable failure from the most recent action invocation.
    public let actionFailure: BrowserWebExtensionActionFailure?

    /// A localized load failure for an installed record that could not start.
    public let loadFailure: String?

    /// The current extension-provided badge text.
    public let badgeText: String

    /// PNG data for the extension-provided action icon.
    public let iconData: Data?

    /// Persisted named permissions currently granted to the extension.
    public let grantedPermissions: [String]

    /// Persisted host match patterns currently granted to the extension.
    public let grantedHosts: [String]

    /// Product capability limits acknowledged during installation.
    public let capabilityNotices: [BrowserWebExtensionCapabilityNotice]

    /// Whether cmux has a trusted update source for this extension.
    public let hasTrustedUpdateSource: Bool

    /// Whether the trusted source contains bytes newer than the installed record.
    public let canUpdate: Bool

    /// Creates an immutable extension presentation item.
    ///
    /// - Parameters:
    ///   - id: The stable WebKit context identifier.
    ///   - name: The extension-provided display name.
    ///   - hasAction: Whether the manifest declares an action surface.
    ///   - isToolbarPinned: Whether the action is pinned to the toolbar.
    ///   - isActionEnabled: Whether the action is enabled for the associated tab.
    ///   - isAwaitingPopup: Whether popup handoff is in progress.
    ///   - badgeText: The current badge text.
    ///   - iconData: PNG data for the extension icon.
    public init(
        id: String,
        managementID: String? = nil,
        name: String,
        version: String = "",
        isEnabled: Bool = true,
        hasAction: Bool,
        isToolbarPinned: Bool,
        isActionEnabled: Bool,
        isAwaitingPopup: Bool,
        actionFailure: BrowserWebExtensionActionFailure? = nil,
        loadFailure: String? = nil,
        badgeText: String,
        iconData: Data?,
        grantedPermissions: [String] = [],
        grantedHosts: [String] = [],
        capabilityNotices: [BrowserWebExtensionCapabilityNotice] = [],
        hasTrustedUpdateSource: Bool = false,
        canUpdate: Bool = false
    ) {
        self.id = id
        self.managementID = managementID
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.hasAction = hasAction
        self.isToolbarPinned = isToolbarPinned
        self.isActionEnabled = isActionEnabled
        self.isAwaitingPopup = isAwaitingPopup
        self.actionFailure = actionFailure
        self.loadFailure = loadFailure
        self.badgeText = badgeText
        self.iconData = iconData
        self.grantedPermissions = grantedPermissions.sorted()
        self.grantedHosts = grantedHosts.sorted()
        self.capabilityNotices = capabilityNotices
        self.hasTrustedUpdateSource = hasTrustedUpdateSource
        self.canUpdate = canUpdate
    }
}

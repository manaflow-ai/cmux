@_spi(CmuxHostTransport) public import CmuxSidebar
import Foundation

extension CMUXSidebarExtensionBlockedReason {
    /// Short status copy describing why the hosted extension is blocked, shown in
    /// the extension details popover's "Status" row.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var blockedStatusText: String {
        switch self {
        case .connectionInterrupted:
            return String(localized: "sidebar.extensions.blocked.status.connectionInterrupted", defaultValue: "Blocked, connection interrupted", bundle: .main)
        case .manifestTimedOut:
            return String(localized: "sidebar.extensions.blocked.status.manifestTimedOut", defaultValue: "Blocked, configuration timed out", bundle: .main)
        case .missingManifest:
            return String(localized: "sidebar.extensions.blocked.status.missingManifest", defaultValue: "Blocked, missing configuration", bundle: .main)
        case .invalidManifest:
            return String(localized: "sidebar.extensions.blocked.status.invalidManifest", defaultValue: "Blocked, invalid configuration", bundle: .main)
        default:
            return String(localized: "sidebar.extensions.blocked.status.failedManifest", defaultValue: "Blocked, configuration unavailable", bundle: .main)
        }
    }

    /// Full-sentence detail copy explaining the blocked state, shown in the
    /// blocked-extension banner and the details popover.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var blockedDetailText: String {
        switch self {
        case .connectionInterrupted:
            return String(localized: "sidebar.extensions.blocked.detail.connectionInterrupted", defaultValue: "CMUX lost the extension connection. No workspace data or actions are being shared.", bundle: .main)
        case .manifestTimedOut:
            return String(localized: "sidebar.extensions.blocked.detail.manifestTimedOut", defaultValue: "CMUX did not receive this extension's configuration in time. No workspace data or actions are being shared.", bundle: .main)
        case .missingManifest:
            return String(localized: "sidebar.extensions.blocked.detail.missingManifest", defaultValue: "CMUX did not receive a sidebar extension configuration, so no workspace data or actions were shared.", bundle: .main)
        case .invalidManifest:
            return String(localized: "sidebar.extensions.blocked.detail.invalidManifest", defaultValue: "CMUX rejected this extension's configuration. No workspace data or actions were shared.", bundle: .main)
        default:
            return String(localized: "sidebar.extensions.blocked.detail.failedManifest", defaultValue: "CMUX could not load this extension's configuration. No workspace data or actions were shared.", bundle: .main)
        }
    }
}

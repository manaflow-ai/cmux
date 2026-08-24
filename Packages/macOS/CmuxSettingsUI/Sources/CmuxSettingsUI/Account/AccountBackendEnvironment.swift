import Foundation

/// The backend environment shown by the Account section's environment
/// picker.
///
/// A package-local mirror of the host's persisted backend override:
/// `CmuxSettingsUI` deliberately does not link the host's auth library
/// (`CMUXAuthCore`), so the host's ``AccountFlow`` implementation maps its
/// own type to and from this one. Production is always selectable so a
/// device can always switch back.
public enum AccountBackendEnvironment: String, CaseIterable, Sendable {
    /// The default backend (cmux.com and the production Stack project).
    case production
    /// The staging backend (a separate deployment with separate accounts
    /// and data).
    case staging

    /// User-facing picker label.
    public var displayName: String {
        switch self {
        case .production:
            return String(
                localized: "settings.account.backendEnvironment.production",
                defaultValue: "Production"
            )
        case .staging:
            return String(
                localized: "settings.account.backendEnvironment.staging",
                defaultValue: "Staging"
            )
        }
    }

}

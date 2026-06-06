import Foundation

/// Whether the settings UI redacts personally-identifying account
/// metadata.
///
/// Used by ``AccountCatalogSection`` to decide whether the user's
/// email, display name, and team affiliation render as-is or as
/// black-bar redactions in the Account section. Users who screenshot
/// settings for support / docs / videos toggle this to ``hidden``
/// before grabbing the frame.
public enum PIIDisplayMode: String, CaseIterable, Sendable, SettingCodable {
    case visible
    case hidden
}

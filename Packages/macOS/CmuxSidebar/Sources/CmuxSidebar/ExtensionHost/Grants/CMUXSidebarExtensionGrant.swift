import CmuxExtensionKit

/// Persisted record of the scopes a user has granted to one installed sidebar
/// extension, keyed by bundle identifier inside ``CMUXSidebarExtensionGrantStore``.
///
/// Internal storage DTO: it is decoded from / encoded to `UserDefaults` by the
/// grant store and never crosses the package boundary.
struct CMUXSidebarExtensionGrant: Codable, Equatable {
    var manifestID: String
    var manifestDisplayName: String
    var apiVersion: CmuxExtensionAPIVersion
    var readScopes: Set<CmuxExtensionScope>
    var actionScopes: Set<CmuxExtensionActionScope>
}

public import Foundation

/// Read/create access to the cmux destination browser profiles an import plan
/// resolves against.
///
/// This is the package seam for ``BrowserImportPlanResolver/realize(plan:profileProvider:strings:)``.
/// The app's profile store conforms to it so the resolver can look up and create
/// destination profiles without the package depending on the app target. The
/// requirements mirror the live store: a snapshot of all profiles, a lookup by
/// identifier, and best-effort creation by display name (returning `nil` on
/// failure).
@MainActor
public protocol BrowserImportProfileProvisioning {
    /// All currently known cmux destination profiles.
    var profiles: [BrowserProfileDefinition] { get }

    /// Looks up an existing profile by identifier.
    /// - Parameter id: The profile identifier.
    /// - Returns: The matching profile, or `nil` if none exists.
    func profileDefinition(id: UUID) -> BrowserProfileDefinition?

    /// Creates a new destination profile with the given display name.
    /// - Parameter name: The requested display name.
    /// - Returns: The created profile, or `nil` if creation failed.
    func createProfile(named name: String) -> BrowserProfileDefinition?
}

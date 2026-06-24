public import Foundation

/// The destination-profile operations a plan realization needs from the cmux
/// profile store.
///
/// Realizing a ``BrowserImportExecutionPlan`` only reads the current profile
/// list, looks profiles up by id, and creates missing destination profiles.
/// This seam lets the realization stay in `CmuxBrowser` while the concrete
/// store (the app's `BrowserProfileStore`) and the package's
/// ``BrowserProfileRepository`` both supply those operations, keeping the
/// WebKit/filesystem-backed store out of the package's dependency graph.
@MainActor
public protocol BrowserImportProfileResolving {
    /// The current destination profiles, default first then alphabetical.
    var profiles: [BrowserProfileDefinition] { get }

    /// Looks up a destination profile by id.
    /// - Parameter id: The profile id.
    /// - Returns: The matching definition, or `nil` when unknown.
    func profileDefinition(id: UUID) -> BrowserProfileDefinition?

    /// Creates a new destination profile.
    /// - Parameter rawName: The requested name; trimmed of surrounding whitespace.
    /// - Returns: The created profile, or `nil` when the trimmed name is empty.
    func createProfile(named rawName: String) -> BrowserProfileDefinition?

    /// The profile the import wizard falls back to when no destination is
    /// otherwise resolvable (the most recently used profile, or the built-in
    /// default).
    var effectiveLastUsedProfileID: UUID { get }

    /// The human-readable name for a profile id, falling back to the default
    /// profile name when the id is unknown.
    /// - Parameter id: The profile id.
    /// - Returns: The profile's display name, or the default name.
    func displayName(for id: UUID) -> String
}

extension BrowserProfileRepository: BrowserImportProfileResolving {}

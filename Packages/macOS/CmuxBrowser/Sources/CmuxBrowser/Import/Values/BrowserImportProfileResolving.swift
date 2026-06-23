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
}

extension BrowserProfileRepository: BrowserImportProfileResolving {}

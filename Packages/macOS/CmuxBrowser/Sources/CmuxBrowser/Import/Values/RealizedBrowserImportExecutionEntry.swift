public import Foundation

/// One resolved import mapping: the source profiles plus the concrete cmux
/// destination profile they will be written to.
///
/// Produced from a ``BrowserImportExecutionEntry`` once every destination
/// request has been resolved (or created) against the profile store, so the
/// destination is now a known id and display name rather than a request.
public struct RealizedBrowserImportExecutionEntry: Sendable {
    /// Source profiles to read data from.
    public let sourceProfiles: [InstalledBrowserProfile]
    /// The resolved cmux destination profile id.
    public let destinationProfileID: UUID
    /// The resolved cmux destination profile display name.
    public let destinationProfileName: String

    /// Creates a resolved import-plan entry.
    ///
    /// - Parameters:
    ///   - sourceProfiles: Source profiles to read data from.
    ///   - destinationProfileID: The resolved cmux destination profile id.
    ///   - destinationProfileName: The resolved cmux destination profile display name.
    public init(
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        destinationProfileName: String
    ) {
        self.sourceProfiles = sourceProfiles
        self.destinationProfileID = destinationProfileID
        self.destinationProfileName = destinationProfileName
    }
}

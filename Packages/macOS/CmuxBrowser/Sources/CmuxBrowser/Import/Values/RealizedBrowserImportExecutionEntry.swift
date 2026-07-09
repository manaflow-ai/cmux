public import Foundation

/// One realized mapping in an import plan: the source profiles to read from and
/// the concrete cmux destination profile they resolved to.
///
/// Unlike ``BrowserImportExecutionEntry`` (which carries a
/// ``BrowserImportDestinationRequest`` that may still need creating), a realized
/// entry names an existing destination profile by identifier and display name.
public struct RealizedBrowserImportExecutionEntry: Sendable {
    /// Source profiles to read data from.
    public let sourceProfiles: [InstalledBrowserProfile]
    /// Identifier of the resolved cmux destination profile.
    public let destinationProfileID: UUID
    /// Display name of the resolved cmux destination profile.
    public let destinationProfileName: String

    /// Creates a realized import-plan entry.
    ///
    /// - Parameters:
    ///   - sourceProfiles: Source profiles to read data from.
    ///   - destinationProfileID: Identifier of the resolved destination profile.
    ///   - destinationProfileName: Display name of the resolved destination profile.
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

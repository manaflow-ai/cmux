public import Foundation

/// A fully resolved import plan: the destination mapping mode, the per-entry
/// resolved source-to-destination mappings, and any profiles created while
/// resolving.
///
/// Produced by ``realized(from:profileResolver:)`` from a
/// ``BrowserImportExecutionPlan`` once every destination request has been
/// resolved or created against the profile store.
public struct RealizedBrowserImportExecutionPlan: Sendable {
    /// How source profiles map onto destination profiles.
    public let mode: BrowserImportDestinationMode
    /// The resolved per-entry source-to-destination mappings.
    public let entries: [RealizedBrowserImportExecutionEntry]
    /// Destination profiles created while resolving the plan.
    public let createdProfiles: [BrowserProfileDefinition]

    /// Creates a resolved import plan.
    ///
    /// - Parameters:
    ///   - mode: How source profiles map onto destination profiles.
    ///   - entries: The resolved per-entry mappings.
    ///   - createdProfiles: Destination profiles created while resolving.
    public init(
        mode: BrowserImportDestinationMode,
        entries: [RealizedBrowserImportExecutionEntry],
        createdProfiles: [BrowserProfileDefinition]
    ) {
        self.mode = mode
        self.entries = entries
        self.createdProfiles = createdProfiles
    }

    /// Resolves a plan's destination requests against the profile store,
    /// creating any missing named destinations.
    ///
    /// - Parameters:
    ///   - plan: The plan whose destination requests should be resolved.
    ///   - profileResolver: The profile store used to look up and create destinations.
    /// - Returns: The resolved plan, including any profiles created during resolution.
    /// - Throws: ``BrowserImportPlanRealizationError`` when a referenced profile
    ///   is missing or a destination profile cannot be created.
    @MainActor
    public static func realized(
        from plan: BrowserImportExecutionPlan,
        profileResolver: any BrowserImportProfileResolving
    ) throws -> RealizedBrowserImportExecutionPlan {
        var realizedEntries: [RealizedBrowserImportExecutionEntry] = []
        var createdProfiles: [BrowserProfileDefinition] = []

        for entry in plan.entries {
            let destinationProfile: BrowserProfileDefinition
            switch entry.destination {
            case .existing(let id):
                guard let existingProfile = profileResolver.profileDefinition(id: id) else {
                    throw BrowserImportPlanRealizationError.missingDestinationProfile(id)
                }
                destinationProfile = existingProfile
            case .createNamed(let name):
                if let existingProfile = BrowserImportExecutionPlan.matchingDestinationProfile(
                    for: name,
                    destinationProfiles: profileResolver.profiles
                ) {
                    destinationProfile = existingProfile
                } else if let createdProfile = profileResolver.createProfile(named: name) {
                    createdProfiles.append(createdProfile)
                    destinationProfile = createdProfile
                } else {
                    throw BrowserImportPlanRealizationError.profileCreationFailed(name)
                }
            }

            realizedEntries.append(
                RealizedBrowserImportExecutionEntry(
                    sourceProfiles: entry.sourceProfiles,
                    destinationProfileID: destinationProfile.id,
                    destinationProfileName: destinationProfile.displayName
                )
            )
        }

        return RealizedBrowserImportExecutionPlan(
            mode: plan.mode,
            entries: realizedEntries,
            createdProfiles: createdProfiles
        )
    }
}

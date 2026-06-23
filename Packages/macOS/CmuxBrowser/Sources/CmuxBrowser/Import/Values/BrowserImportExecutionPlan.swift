public import Foundation

/// A resolved import plan: the destination mapping mode plus per-entry
/// source-to-destination mappings.
public struct BrowserImportExecutionPlan: Equatable, Sendable {
    /// How source profiles map onto destination profiles.
    public var mode: BrowserImportDestinationMode
    /// The individual source-to-destination mappings.
    public var entries: [BrowserImportExecutionEntry]

    /// Creates an import execution plan.
    ///
    /// - Parameters:
    ///   - mode: How source profiles map onto destination profiles.
    ///   - entries: The individual source-to-destination mappings.
    public init(mode: BrowserImportDestinationMode, entries: [BrowserImportExecutionEntry]) {
        self.mode = mode
        self.entries = entries
    }
}

extension BrowserImportExecutionPlan {
    /// Builds the default plan for a selection: a single shared destination for
    /// zero or one source profile (matching by name when possible), otherwise a
    /// separate-profiles plan.
    ///
    /// - Parameters:
    ///   - selectedSourceProfiles: The chosen source profiles.
    ///   - destinationProfiles: The available cmux destination profiles.
    ///   - preferredSingleDestinationProfileID: Destination to use when no name match exists.
    /// - Returns: The default execution plan.
    @MainActor
    public static func defaultPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition],
        preferredSingleDestinationProfileID: UUID
    ) -> BrowserImportExecutionPlan {
        let resolvedSourceProfiles = selectedSourceProfiles.isEmpty ? [] : selectedSourceProfiles

        guard resolvedSourceProfiles.count > 1 else {
            let destinationRequest: BrowserImportDestinationRequest
            if let sourceProfile = resolvedSourceProfiles.first,
               let matchingProfile = matchingDestinationProfile(
                for: sourceProfile.displayName,
                destinationProfiles: destinationProfiles
               ) {
                destinationRequest = .existing(matchingProfile.id)
            } else {
                destinationRequest = .existing(preferredSingleDestinationProfileID)
            }

            return BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: resolvedSourceProfiles.map {
                    BrowserImportExecutionEntry(
                        sourceProfiles: [$0],
                        destination: destinationRequest
                    )
                }
            )
        }

        return separateProfilesPlan(
            selectedSourceProfiles: resolvedSourceProfiles,
            destinationProfiles: destinationProfiles
        )
    }

    /// Builds a plan that maps each source profile to its own destination,
    /// reusing a name-matched destination when one exists and creating a fresh
    /// uniquely-named destination otherwise.
    ///
    /// - Parameters:
    ///   - selectedSourceProfiles: The chosen source profiles.
    ///   - destinationProfiles: The available cmux destination profiles.
    /// - Returns: The separate-profiles execution plan.
    public static func separateProfilesPlan(
        selectedSourceProfiles: [InstalledBrowserProfile],
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserImportExecutionPlan {
        var reservedNames = Set(destinationProfiles.map { normalizedProfileName($0.displayName) })

        return BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: selectedSourceProfiles.map { profile in
                if let matchingProfile = matchingDestinationProfile(
                    for: profile.displayName,
                    destinationProfiles: destinationProfiles
                ) {
                    return BrowserImportExecutionEntry(
                        sourceProfiles: [profile],
                        destination: .existing(matchingProfile.id)
                    )
                }

                let createName = nextCreateName(
                    baseName: profile.displayName,
                    takenNames: reservedNames
                )
                reservedNames.insert(normalizedProfileName(createName))
                return BrowserImportExecutionEntry(
                    sourceProfiles: [profile],
                    destination: .createNamed(createName)
                )
            }
        )
    }

    /// Finds a destination profile whose normalized name matches the source name.
    static func matchingDestinationProfile(
        for sourceProfileName: String,
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserProfileDefinition? {
        let normalizedSourceName = normalizedProfileName(sourceProfileName)
        guard !normalizedSourceName.isEmpty else { return nil }
        return destinationProfiles.first {
            normalizedProfileName($0.displayName) == normalizedSourceName
        }
    }

    private static func nextCreateName(
        baseName: String,
        takenNames: Set<String>
    ) -> String {
        let trimmedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseName = trimmedBaseName.isEmpty ? "Profile" : trimmedBaseName
        if !takenNames.contains(normalizedProfileName(resolvedBaseName)) {
            return resolvedBaseName
        }

        var suffix = 2
        while true {
            let candidate = "\(resolvedBaseName) (\(suffix))"
            if !takenNames.contains(normalizedProfileName(candidate)) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func normalizedProfileName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

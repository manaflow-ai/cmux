public import Foundation

/// Resolves browser-import destination mappings: turns a set of selected source
/// profiles into a ``BrowserImportExecutionPlan``, and realizes a plan against a
/// live destination-profile provider into a ``RealizedBrowserImportExecutionPlan``.
///
/// Planning (``defaultPlan(selectedSourceProfiles:destinationProfiles:preferredSingleDestinationProfileID:)``
/// and ``separateProfilesPlan(selectedSourceProfiles:destinationProfiles:)``) is
/// pure compute over value types. ``realize(plan:profileProvider:strings:)`` is the
/// only app-coupled step: it reads and creates destination profiles through the
/// ``BrowserImportProfileProvisioning`` seam, and surfaces failures with localized
/// strings supplied by the app (see ``BrowserImportRealizationStrings``).
public struct BrowserImportPlanResolver: Sendable {
    /// Creates a plan resolver. The resolver holds no state.
    public init() {}

    /// Builds the default import plan for a set of selected source profiles.
    ///
    /// A single source profile maps to one destination (reusing a same-named
    /// existing destination when present, otherwise the preferred single
    /// destination). Multiple source profiles fan out to separate destinations
    /// via ``separateProfilesPlan(selectedSourceProfiles:destinationProfiles:)``.
    ///
    /// - Parameters:
    ///   - selectedSourceProfiles: The chosen source profiles.
    ///   - destinationProfiles: Existing cmux destination profiles to match against.
    ///   - preferredSingleDestinationProfileID: Fallback destination for a lone source profile.
    /// - Returns: The resolved execution plan.
    public func defaultPlan(
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
    /// reusing same-named existing destinations and creating uniquely-named
    /// destinations otherwise.
    ///
    /// - Parameters:
    ///   - selectedSourceProfiles: The chosen source profiles.
    ///   - destinationProfiles: Existing cmux destination profiles to match against.
    /// - Returns: The resolved separate-profiles execution plan.
    public func separateProfilesPlan(
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

    /// Realizes a plan against a live destination-profile provider, creating
    /// destinations as required.
    ///
    /// - Parameters:
    ///   - plan: The execution plan to realize.
    ///   - profileProvider: The destination-profile read/create seam.
    ///   - strings: App-resolved localized failure messages.
    /// - Throws: ``BrowserImportPlanRealizationError`` if a destination is missing
    ///   or cannot be created.
    /// - Returns: The realized plan with concrete destination identifiers.
    @MainActor
    public func realize(
        plan: BrowserImportExecutionPlan,
        profileProvider: any BrowserImportProfileProvisioning,
        strings: BrowserImportRealizationStrings
    ) throws -> RealizedBrowserImportExecutionPlan {
        var realizedEntries: [RealizedBrowserImportExecutionEntry] = []
        var createdProfiles: [BrowserProfileDefinition] = []

        for entry in plan.entries {
            let destinationProfile: BrowserProfileDefinition
            switch entry.destination {
            case .existing(let id):
                guard let existingProfile = profileProvider.profileDefinition(id: id) else {
                    throw BrowserImportPlanRealizationError.missingDestinationProfile(
                        id,
                        localizedMessage: strings.destinationMissing
                    )
                }
                destinationProfile = existingProfile
            case .createNamed(let name):
                if let existingProfile = matchingDestinationProfile(
                    for: name,
                    destinationProfiles: profileProvider.profiles
                ) {
                    destinationProfile = existingProfile
                } else if let createdProfile = profileProvider.createProfile(named: name) {
                    createdProfiles.append(createdProfile)
                    destinationProfile = createdProfile
                } else {
                    throw BrowserImportPlanRealizationError.profileCreationFailed(
                        name: name,
                        localizedMessage: String(format: strings.destinationCreateFailedFormat, name)
                    )
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

    private func matchingDestinationProfile(
        for sourceProfileName: String,
        destinationProfiles: [BrowserProfileDefinition]
    ) -> BrowserProfileDefinition? {
        let normalizedSourceName = normalizedProfileName(sourceProfileName)
        guard !normalizedSourceName.isEmpty else { return nil }
        return destinationProfiles.first {
            normalizedProfileName($0.displayName) == normalizedSourceName
        }
    }

    private func nextCreateName(
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

    private func normalizedProfileName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

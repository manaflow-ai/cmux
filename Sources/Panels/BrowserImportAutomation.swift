import Foundation
import CmuxBrowser

enum BrowserImportAutomation {
    static func importCookies(
        params: [String: Any],
        coordinator: BrowserDataImportCoordinator
    ) async throws -> BrowserImportOutcome {
        let browsers = await coordinator.detectInstalledBrowsers()
        guard !browsers.isEmpty else {
            throw BrowserImportAutomationError.noBrowsers
        }

        let browser = try selectedBrowser(from: browsers, params: params)
        let sourceProfiles = try selectedSourceProfiles(from: browser, params: params)
        let domainFilters = BrowserDataImporter.parseDomainFilters(domainFilterText(from: params))

        let realizedPlan: RealizedBrowserImportExecutionPlan = try await MainActor.run {
            let destinationProfiles = BrowserProfileStore.shared.profiles
            let preferredDestinationProfileID = try resolvedDestinationProfileID(
                params: params,
                destinationProfiles: destinationProfiles
            )

            let plan: BrowserImportExecutionPlan
            if let preferredDestinationProfileID {
                let mode: BrowserImportDestinationMode = sourceProfiles.count > 1 ? .mergeIntoOne : .singleDestination
                plan = BrowserImportExecutionPlan(
                    mode: mode,
                    entries: [
                        BrowserImportExecutionEntry(
                            sourceProfiles: sourceProfiles,
                            destination: .existing(preferredDestinationProfileID)
                        )
                    ]
                )
            } else {
                plan = BrowserImportPlanResolver.defaultPlan(
                    selectedSourceProfiles: sourceProfiles,
                    destinationProfiles: destinationProfiles,
                    preferredSingleDestinationProfileID: BrowserProfileStore.shared.effectiveLastUsedProfileID
                )
            }

            return try BrowserImportPlanResolver.realize(plan: plan)
        }

        return await BrowserDataImporter.importData(
            from: browser,
            plan: realizedPlan,
            scope: .cookiesOnly,
            domainFilters: domainFilters
        )
    }

    private static func selectedBrowser(
        from browsers: [InstalledBrowserCandidate],
        params: [String: Any]
    ) throws -> InstalledBrowserCandidate {
        guard let query = stringParam(params, keys: ["browser", "from", "source"]) else {
            let sortedBrowsers = browsers.sorted { lhs, rhs in
                if lhs.detectionScore != rhs.detectionScore {
                    return lhs.detectionScore > rhs.detectionScore
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            guard let browser = sortedBrowsers.first else {
                throw BrowserImportAutomationError.noBrowsers
            }
            return browser
        }

        guard let browser = browsers.first(where: { matchesBrowser($0, query: query) }) else {
            throw BrowserImportAutomationError.browserNotFound(query)
        }
        return browser
    }

    private static func selectedSourceProfiles(
        from browser: InstalledBrowserCandidate,
        params: [String: Any]
    ) throws -> [InstalledBrowserProfile] {
        guard !browser.profiles.isEmpty else {
            throw BrowserImportAutomationError.noProfiles(browser.displayName)
        }

        if BrowserAutomationParameters(values: params).bool(keys: ["all_profiles", "all_source_profiles"]) {
            return browser.profiles
        }

        let queries = stringListParam(params, keys: ["profile", "source_profile", "source_profiles"])
        guard !queries.isEmpty else {
            if let defaultProfile = browser.profiles.first(where: \.isDefault) {
                return [defaultProfile]
            }
            return [browser.profiles[0]]
        }

        var result: [InstalledBrowserProfile] = []
        var seen = Set<String>()
        for query in queries {
            guard let profile = browser.profiles.first(where: { matchesProfile($0, query: query) }) else {
                throw BrowserImportAutomationError.sourceProfileNotFound(query)
            }
            guard seen.insert(profile.id).inserted else { continue }
            result.append(profile)
        }
        return result
    }

    @MainActor
    private static func resolvedDestinationProfileID(
        params: [String: Any],
        destinationProfiles: [BrowserProfileDefinition]
    ) throws -> UUID? {
        guard let query = stringParam(params, keys: ["destination_profile", "to_profile", "to"]) else {
            return nil
        }

        if let uuid = UUID(uuidString: query),
           destinationProfiles.contains(where: { $0.id == uuid }) {
            return uuid
        }

        if let profile = destinationProfiles.first(where: {
            $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
        }) {
            return profile.id
        }

        guard BrowserAutomationParameters(values: params).bool(keys: ["create_destination_profile", "create_profile"]) else {
            throw BrowserImportAutomationError.destinationProfileNotFound(query)
        }

        guard let profile = BrowserProfileStore.shared.createProfile(named: query) else {
            throw BrowserImportAutomationError.destinationProfileCreationFailed(query)
        }
        return profile.id
    }

    private static func matchesBrowser(_ browser: InstalledBrowserCandidate, query: String) -> Bool {
        browser.matchesLookupQuery(query)
    }

    private static func matchesProfile(_ profile: InstalledBrowserProfile, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if profile.id.lowercased() == normalized { return true }
        if profile.displayName.lowercased() == normalized { return true }
        if profile.rootURL.lastPathComponent.lowercased() == normalized { return true }
        return false
    }

    private static func domainFilterText(from params: [String: Any]) -> String {
        stringListParam(params, keys: ["domain", "domains", "domain_filters"])
            .joined(separator: ",")
    }

    private static func stringParam(_ params: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func stringListParam(_ params: [String: Any], keys: [String]) -> [String] {
        var result: [String] = []
        for key in keys {
            if let value = params[key] as? String {
                let parsed = value
                    .components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                result.append(contentsOf: parsed)
            } else if let values = params[key] as? [String] {
                result.append(
                    contentsOf: values
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
        }
        return result
    }
}

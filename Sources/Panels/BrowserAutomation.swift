import Foundation
import CmuxBrowser

enum BrowserImportAutomationError: LocalizedError, CustomStringConvertible {
    case noBrowsers
    case browserNotFound(String)
    case noProfiles(String)
    case sourceProfileNotFound(String)
    case destinationProfileNotFound(String)
    case destinationProfileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBrowsers:
            return String(
                localized: "browser.import.automation.error.noBrowsers",
                defaultValue: "No importable browsers found"
            )
        case .browserNotFound(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.import.automation.error.browserNotFound",
                    defaultValue: "No importable browser matches '%@'"
                ),
                query
            )
        case .noProfiles(let browserName):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.import.automation.error.noProfiles",
                    defaultValue: "No source profiles found for %@"
                ),
                browserName
            )
        case .sourceProfileNotFound(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.import.automation.error.sourceProfileNotFound",
                    defaultValue: "No source profile matches '%@'"
                ),
                query
            )
        case .destinationProfileNotFound(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.import.automation.error.destinationProfileNotFound",
                    defaultValue: "No cmux browser profile matches '%@'"
                ),
                query
            )
        case .destinationProfileCreationFailed(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.import.automation.error.destinationProfileCreationFailed",
                    defaultValue: "Failed to create cmux browser profile '%@'"
                ),
                name
            )
        }
    }

    var description: String {
        errorDescription ?? String(
            localized: "browser.import.automation.error.fallback",
            defaultValue: "Browser import failed"
        )
    }
}

enum BrowserProfileAutomationError: LocalizedError, CustomStringConvertible {
    case missingName
    case missingProfile
    case profileNotFound(String)
    case ambiguousProfile(String)
    case profileCreationFailed(String)
    case profileRenameFailed(String)
    case cannotDeleteDefaultProfile
    case profileInUse(String, Int)
    case profileDeleteFailed(String)
    case profileClearFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            return String(
                localized: "browser.profile.automation.error.missingName",
                defaultValue: "Missing browser profile name"
            )
        case .missingProfile:
            return String(
                localized: "browser.profile.automation.error.missingProfile",
                defaultValue: "Missing browser profile"
            )
        case .profileNotFound(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileNotFound",
                    defaultValue: "No cmux browser profile matches '%@'"
                ),
                query
            )
        case .ambiguousProfile(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.ambiguousProfile",
                    defaultValue: "Multiple cmux browser profiles match '%@'. Use the profile ID instead."
                ),
                query
            )
        case .profileCreationFailed(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileCreationFailed",
                    defaultValue: "Failed to create cmux browser profile '%@'"
                ),
                name
            )
        case .profileRenameFailed(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileRenameFailed",
                    defaultValue: "Failed to rename cmux browser profile to '%@'"
                ),
                name
            )
        case .cannotDeleteDefaultProfile:
            return String(
                localized: "browser.profile.automation.error.cannotDeleteDefaultProfile",
                defaultValue: "The default browser profile cannot be deleted"
            )
        case .profileInUse(let name, let count):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileInUse",
                    defaultValue: "Cannot delete cmux browser profile '%@' while %d browser panel(s) are using it"
                ),
                name,
                count
            )
        case .profileDeleteFailed(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileDeleteFailed",
                    defaultValue: "Failed to delete cmux browser profile '%@'"
                ),
                name
            )
        case .profileClearFailed(let name):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileClearFailed",
                    defaultValue: "Failed to clear cmux browser profile '%@'"
                ),
                name
            )
        }
    }

    var description: String {
        errorDescription ?? String(
            localized: "browser.profile.automation.error.fallback",
            defaultValue: "Browser profile command failed"
        )
    }
}

private func browserAutomationBoolParam(_ params: [String: Any], keys: [String]) -> Bool {
    for key in keys {
        if let value = params[key] as? Bool {
            return value
        }
        if let value = params[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            default:
                continue
            }
        }
    }
    return false
}

enum BrowserProfileAutomation {
    static func list(params _: [String: Any]) async throws -> [String: Any] {
        await MainActor.run {
            let store = BrowserProfileStore.shared
            return [
                "current_profile_id": store.effectiveLastUsedProfileID.uuidString,
                "profiles": store.profiles.map { profilePayload($0, currentProfileID: store.effectiveLastUsedProfileID) },
            ]
        }
    }

    static func create(params: [String: Any]) async throws -> [String: Any] {
        let name = try requiredString(params, keys: ["name"])
        return try await MainActor.run {
            guard let profile = BrowserProfileStore.shared.createProfile(named: name) else {
                throw BrowserProfileAutomationError.profileCreationFailed(name)
            }
            return [
                "created": true,
                "profile": profilePayload(profile, currentProfileID: BrowserProfileStore.shared.effectiveLastUsedProfileID),
            ]
        }
    }

    static func rename(params: [String: Any]) async throws -> [String: Any] {
        let query = try requiredString(params, keys: ["profile", "id", "name"])
        let newName = try requiredString(params, keys: ["new_name", "to"])
        return try await MainActor.run {
            let store = BrowserProfileStore.shared
            guard let profile = try resolveProfile(query, profiles: store.profiles) else {
                throw BrowserProfileAutomationError.profileNotFound(query)
            }
            let oldName = profile.displayName
            guard store.renameProfile(id: profile.id, to: newName),
                  let renamed = store.profileDefinition(id: profile.id) else {
                throw BrowserProfileAutomationError.profileRenameFailed(newName)
            }
            return [
                "renamed": true,
                "old_name": oldName,
                "profile": profilePayload(renamed, currentProfileID: store.effectiveLastUsedProfileID),
            ]
        }
    }

    @MainActor
    static func clear(params: [String: Any]) async throws -> [String: Any] {
        let targets = try targetProfiles(params: params, allowAll: true)
        let force = browserAutomationBoolParam(params, keys: ["force"])
        if !force {
            for profile in targets {
                let livePanelCount = liveBrowserPanelCount(profileID: profile.id)
                guard livePanelCount == 0 else {
                    throw BrowserProfileAutomationError.profileInUse(profile.displayName, livePanelCount)
                }
            }
        }
        var clearedProfiles: [[String: Any]] = []
        for profile in targets {
            if !force {
                let livePanelCount = liveBrowserPanelCount(profileID: profile.id)
                guard livePanelCount == 0 else {
                    throw BrowserProfileAutomationError.profileInUse(profile.displayName, livePanelCount)
                }
            }
            guard let outcome = await BrowserProfileStore.shared.clearProfileData(id: profile.id) else {
                throw BrowserProfileAutomationError.profileClearFailed(profile.displayName)
            }
            clearedProfiles.append(outcome.socketPayload)
        }
        return [
            "cleared": true,
            "count": clearedProfiles.count,
            "profiles": clearedProfiles,
        ]
    }

    static func delete(params: [String: Any]) async throws -> [String: Any] {
        let query = try requiredString(params, keys: ["profile", "id", "name"])
        let profile = try await MainActor.run {
            let profiles = BrowserProfileStore.shared.profiles
            guard let profile = try resolveProfile(query, profiles: profiles) else {
                throw BrowserProfileAutomationError.profileNotFound(query)
            }
            guard !profile.isBuiltInDefault else {
                throw BrowserProfileAutomationError.cannotDeleteDefaultProfile
            }
            let livePanelCount = liveBrowserPanelCount(profileID: profile.id)
            guard livePanelCount == 0 else {
                throw BrowserProfileAutomationError.profileInUse(profile.displayName, livePanelCount)
            }
            return profile
        }

        _ = await BrowserProfileStore.shared.clearProfileData(id: profile.id)
        return try await MainActor.run {
            let livePanelCount = liveBrowserPanelCount(profileID: profile.id)
            guard livePanelCount == 0 else {
                throw BrowserProfileAutomationError.profileInUse(profile.displayName, livePanelCount)
            }
            guard let deleted = BrowserProfileStore.shared.deleteProfile(id: profile.id) else {
                throw BrowserProfileAutomationError.profileDeleteFailed(profile.displayName)
            }
            return [
                "deleted": true,
                "profile": profilePayload(deleted, currentProfileID: BrowserProfileStore.shared.effectiveLastUsedProfileID),
            ]
        }
    }

    @MainActor
    private static func targetProfiles(params: [String: Any], allowAll: Bool) throws -> [BrowserProfileDefinition] {
        let store = BrowserProfileStore.shared
        if allowAll, browserAutomationBoolParam(params, keys: ["all", "all_profiles"]) {
            return store.profiles
        }
        let query = try requiredString(params, keys: ["profile", "id", "name"])
        guard let profile = try resolveProfile(query, profiles: store.profiles) else {
            throw BrowserProfileAutomationError.profileNotFound(query)
        }
        return [profile]
    }

    private static func profilePayload(_ profile: BrowserProfileDefinition, currentProfileID: UUID) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "current": profile.id == currentProfileID,
        ]
    }

    private static func resolveProfile(
        _ query: String,
        profiles: [BrowserProfileDefinition]
    ) throws -> BrowserProfileDefinition? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let uuid = UUID(uuidString: normalized),
           let profile = profiles.first(where: { $0.id == uuid }) {
            return profile
        }
        let matches = profiles.filter {
            $0.slug.localizedCaseInsensitiveCompare(normalized) == .orderedSame ||
                $0.displayName.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }
        if matches.count > 1 {
            throw BrowserProfileAutomationError.ambiguousProfile(query)
        }
        return matches.first
    }

    private static func requiredString(_ params: [String: Any], keys: [String]) throws -> String {
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        if keys.contains("profile") || keys.contains("id") {
            throw BrowserProfileAutomationError.missingProfile
        }
        throw BrowserProfileAutomationError.missingName
    }

    @MainActor
    private static func liveBrowserPanelCount(profileID: UUID) -> Int {
        guard let app = AppDelegate.shared else { return 0 }
        return app.registeredMainWindows.reduce(0) { contextCount, context in
            contextCount + context.tabManager.tabs.reduce(0) { workspaceCount, workspace in
                workspaceCount + workspace.panels.values.reduce(0) { panelCount, panel in
                    guard let browserPanel = panel as? BrowserPanel,
                          browserPanel.profileID == profileID else {
                        return panelCount
                    }
                    return panelCount + 1
                }
            }
        }
    }
}

enum BrowserImportAutomation {
    static func importCookies(params: [String: Any]) async throws -> BrowserImportOutcome {
        let browsers = BrowserInstalledBrowserDetector().detectInstalledBrowsers()
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

        if browserAutomationBoolParam(params, keys: ["all_profiles", "all_source_profiles"]) {
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

        guard browserAutomationBoolParam(params, keys: ["create_destination_profile", "create_profile"]) else {
            throw BrowserImportAutomationError.destinationProfileNotFound(query)
        }

        guard let profile = BrowserProfileStore.shared.createProfile(named: query) else {
            throw BrowserImportAutomationError.destinationProfileCreationFailed(query)
        }
        return profile.id
    }

    private static func matchesBrowser(_ browser: InstalledBrowserCandidate, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if browser.id.lowercased() == normalized { return true }
        if browser.displayName.lowercased() == normalized { return true }
        return browser.descriptor.appNames.contains {
            $0.replacingOccurrences(of: ".app", with: "").lowercased() == normalized
        }
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

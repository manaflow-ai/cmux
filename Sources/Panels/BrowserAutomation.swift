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
    case browserDisabled
    case invalidProfileSelector
    case multipleProfileSelectors
    case profileRequiresBrowserPane
    case profileUnavailableInRemoteWorkspace
    case profileNotFound(String)
    case ambiguousProfile(String, [BrowserProfileDefinition])
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
        case .browserDisabled:
            return String(
                localized: "browser.profile.automation.error.browserDisabled",
                defaultValue: "Browser profiles cannot be used while the cmux browser is disabled"
            )
        case .invalidProfileSelector:
            return String(
                localized: "browser.profile.automation.error.invalidProfileSelector",
                defaultValue: "Browser profile must be a non-empty name or UUID"
            )
        case .multipleProfileSelectors:
            return String(
                localized: "browser.profile.automation.error.multipleProfileSelectors",
                defaultValue: "Specify only one browser profile selector"
            )
        case .profileRequiresBrowserPane:
            return String(
                localized: "browser.profile.automation.error.profileRequiresBrowserPane",
                defaultValue: "Browser profiles can only be used when creating a browser pane"
            )
        case .profileUnavailableInRemoteWorkspace:
            return String(
                localized: "browser.profile.automation.error.profileUnavailableInRemoteWorkspace",
                defaultValue: "Browser profiles cannot be selected when creating a browser pane in a remote workspace"
            )
        case .profileNotFound(let query):
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.profileNotFound",
                    defaultValue: "No cmux browser profile matches '%@'. Run 'cmux browser profiles' to list available profiles."
                ),
                query
            )
        case .ambiguousProfile(let query, let candidates):
            let candidateList = candidates
                .map { "\($0.displayName) (\($0.id.uuidString))" }
                .joined(separator: ", ")
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.profile.automation.error.ambiguousProfile",
                    defaultValue: "Multiple cmux browser profiles match '%@': %@. Use a profile UUID."
                ),
                query,
                candidateList
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
        let force = BrowserAutomationParameters(values: params).bool(keys: ["force"])
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
        if allowAll, BrowserAutomationParameters(values: params).bool(keys: ["all", "all_profiles"]) {
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
            throw BrowserProfileAutomationError.ambiguousProfile(query, matches)
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
    static func liveBrowserPanelCount(profileID: UUID) -> Int {
        guard let app = AppDelegate.shared else { return 0 }
        let workspaceCount = app.mainWindowContexts.values.reduce(0) { contextCount, context in
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
        let dockCount = DockSplitStore.liveStores.reduce(0) { count, dock in
            count + dock.panels.values.reduce(0) { panelCount, panel in
                guard let browserPanel = panel as? BrowserPanel,
                      browserPanel.profileID == profileID else {
                    return panelCount
                }
                return panelCount + 1
            }
        }
        return workspaceCount + dockCount
    }
}

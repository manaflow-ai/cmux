import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

struct BrowserProfileDefinition: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    let createdAt: Date
    let isBuiltInDefault: Bool

    var slug: String {
        if isBuiltInDefault {
            return "default"
        }

        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? id.uuidString.lowercased() : normalized
    }
}

struct BrowserProfileClearOutcome: Sendable {
    let profile: BrowserProfileDefinition
    let clearedWebsiteDataTypes: [String]
    let clearedHistory: Bool

    var socketPayload: [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "cleared_website_data_types": clearedWebsiteDataTypes,
            "cleared_history": clearedHistory,
        ]
    }
}

@MainActor
final class BrowserProfileStore: ObservableObject {
    static let shared = BrowserProfileStore()

    private static let profilesDefaultsKey = "browserProfiles.v1"
    private static let lastUsedProfileDefaultsKey = "browserProfiles.lastUsed"
    private static let builtInDefaultProfileID = UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!

    @Published private(set) var profiles: [BrowserProfileDefinition] = []
    @Published private(set) var lastUsedProfileID: UUID = builtInDefaultProfileID

    private let defaults: UserDefaults
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private var historyStores: [UUID: BrowserHistoryStore] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var builtInDefaultProfileID: UUID {
        Self.builtInDefaultProfileID
    }

    var effectiveLastUsedProfileID: UUID {
        profileDefinition(id: lastUsedProfileID) != nil ? lastUsedProfileID : Self.builtInDefaultProfileID
    }

    func profileDefinition(id: UUID) -> BrowserProfileDefinition? {
        profiles.first(where: { $0.id == id })
    }

    func displayName(for id: UUID) -> String {
        profileDefinition(id: id)?.displayName
        ?? String(localized: "browser.profile.default", defaultValue: "Default")
    }

    func createProfile(named rawName: String) -> BrowserProfileDefinition? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let profile = BrowserProfileDefinition(
            id: UUID(),
            displayName: name,
            createdAt: Date(),
            isBuiltInDefault: false
        )
        profiles.append(profile)
        profiles.sort {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persist()
        noteUsed(profile.id)
        return profile
    }

    func renameProfile(id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltInDefault else {
            return false
        }
        profiles[index].displayName = name
        profiles.sort {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persist()
        return true
    }

    func canRenameProfile(id: UUID) -> Bool {
        guard let profile = profileDefinition(id: id) else { return false }
        return !profile.isBuiltInDefault
    }

    func deleteProfile(id: UUID) -> BrowserProfileDefinition? {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltInDefault else {
            return nil
        }
        let removed = profiles.remove(at: index)
        let historyDirectoryURL = historyFileURL(for: id)?.deletingLastPathComponent()
        historyStores[id]?.cancelPendingSaves()
        dataStores.removeValue(forKey: id)
        historyStores.removeValue(forKey: id)
        if lastUsedProfileID == id {
            lastUsedProfileID = Self.builtInDefaultProfileID
            defaults.set(lastUsedProfileID.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
        persist()
        if let historyDirectoryURL {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: historyDirectoryURL)
            }
        }
        return removed
    }

    func clearProfileData(id: UUID) async -> BrowserProfileClearOutcome? {
        guard let profile = profileDefinition(id: id) else { return nil }
        let store = websiteDataStore(for: id)
        let historyURL = historyFileURL(for: id)
        historyStore(for: id).clearHistoryWithoutLoadingPersistedFile()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        if let historyURL {
            await Self.removeItemIfExists(at: historyURL)
        }
        return BrowserProfileClearOutcome(
            profile: profile,
            clearedWebsiteDataTypes: Array(dataTypes).sorted(),
            clearedHistory: true
        )
    }

    @Sendable private nonisolated static func removeItemIfExists(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    func noteUsed(_ id: UUID) {
        guard profileDefinition(id: id) != nil else { return }
        if lastUsedProfileID != id {
            lastUsedProfileID = id
            defaults.set(id.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
    }

    func websiteDataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if profileID == Self.builtInDefaultProfileID {
            return .default()
        }
        if let existing = dataStores[profileID] {
            return existing
        }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    func historyStore(for profileID: UUID) -> BrowserHistoryStore {
        if profileID == Self.builtInDefaultProfileID {
            return .shared
        }
        if let existing = historyStores[profileID] {
            return existing
        }
        let store = BrowserHistoryStore(fileURL: historyFileURL(for: profileID))
        historyStores[profileID] = store
        return store
    }

    func historyFileURL(for profileID: UUID) -> URL? {
        if profileID == Self.builtInDefaultProfileID {
            return BrowserHistoryStore.defaultHistoryFileURLForCurrentBundle()
        }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let namespace = BrowserHistoryStore.normalizedBrowserHistoryNamespaceForBundleIdentifier(bundleId)
        let profilesDir = appSupport
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("browser_profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        return profilesDir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    func flushPendingSaves() {
        BrowserHistoryStore.shared.flushPendingSaves()
        for store in historyStores.values {
            store.flushPendingSaves()
        }
    }

    private func load() {
        let builtInDefaultProfile = BrowserProfileDefinition(
            id: Self.builtInDefaultProfileID,
            displayName: String(localized: "browser.profile.default", defaultValue: "Default"),
            createdAt: Date(timeIntervalSince1970: 0),
            isBuiltInDefault: true
        )

        if let data = defaults.data(forKey: Self.profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([BrowserProfileDefinition].self, from: data),
           !decoded.isEmpty {
            var resolvedProfiles = decoded.filter { $0.id != Self.builtInDefaultProfileID }
            resolvedProfiles.append(builtInDefaultProfile)
            profiles = sortedProfiles(resolvedProfiles)
        } else {
            profiles = [builtInDefaultProfile]
            persist()
        }

        if let rawLastUsed = defaults.string(forKey: Self.lastUsedProfileDefaultsKey),
           let parsed = UUID(uuidString: rawLastUsed),
           profileDefinition(id: parsed) != nil {
            lastUsedProfileID = parsed
        } else {
            lastUsedProfileID = Self.builtInDefaultProfileID
            defaults.set(lastUsedProfileID.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesDefaultsKey)
    }

    private func sortedProfiles(_ profiles: [BrowserProfileDefinition]) -> [BrowserProfileDefinition] {
        profiles.sorted {
            if $0.isBuiltInDefault != $1.isBuiltInDefault {
                return $0.isBuiltInDefault && !$1.isBuiltInDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

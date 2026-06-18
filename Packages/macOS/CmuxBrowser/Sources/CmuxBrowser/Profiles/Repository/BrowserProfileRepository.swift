public import Foundation
import Observation

/// Durable source of truth for browser profiles.
///
/// Owns the persisted profile list, the last-used profile selection, and the
/// per-profile `WKWebsiteDataStore` / history-store caches. Backed by
/// `UserDefaults` and the injected ``BrowserProfileHistoryProviding``,
/// ``BrowserProfileWebsiteDataStoreProviding``, and ``BrowserProfileFileRemoving``
/// seams so the WebKit, filesystem, and bundle dependencies stay in the app
/// target. The app's `BrowserProfileStore` is a thin `ObservableObject` facade
/// over this repository.
///
/// `@MainActor` because it seeds synchronously in `init` and is consumed by the
/// main-thread facade and views; mirrors the original `@MainActor` store exactly.
@MainActor
@Observable
public final class BrowserProfileRepository {
    /// `UserDefaults` key for the encoded profile list.
    public static let profilesDefaultsKey = "browserProfiles.v1"
    /// `UserDefaults` key for the last-used profile id string.
    public static let lastUsedProfileDefaultsKey = "browserProfiles.lastUsed"
    /// Stable identifier of the immovable built-in default profile.
    public static let builtInDefaultProfileID = UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!

    /// The current profile list, default first then alphabetical by display name.
    public private(set) var profiles: [BrowserProfileDefinition] = []
    /// The last-used profile id; defaults to the built-in default.
    public private(set) var lastUsedProfileID: UUID = builtInDefaultProfileID

    private let defaults: UserDefaults
    private let historyProvider: any BrowserProfileHistoryProviding
    private let websiteDataStoreProvider: any BrowserProfileWebsiteDataStoreProviding
    private let fileRemover: any BrowserProfileFileRemoving
    private let bundleIdentifier: String
    private let defaultProfileDisplayName: String

    private var dataStores: [UUID: AnyObject] = [:]
    private var historyStores: [UUID: any BrowserProfileHistoryStore] = [:]

    /// Creates the repository and synchronously loads persisted state.
    /// - Parameters:
    ///   - defaults: Backing `UserDefaults`.
    ///   - historyProvider: Seam producing per-profile and shared history stores.
    ///   - websiteDataStoreProvider: Seam producing and wiping `WKWebsiteDataStore` handles.
    ///   - fileRemover: Seam deleting profile-owned files.
    ///   - bundleIdentifier: The running app's bundle identifier (falls back to `"cmux"` upstream).
    ///   - defaultProfileDisplayName: Localized display name for the built-in default profile.
    public init(
        defaults: UserDefaults,
        historyProvider: any BrowserProfileHistoryProviding,
        websiteDataStoreProvider: any BrowserProfileWebsiteDataStoreProviding,
        fileRemover: any BrowserProfileFileRemoving,
        bundleIdentifier: String,
        defaultProfileDisplayName: String
    ) {
        self.defaults = defaults
        self.historyProvider = historyProvider
        self.websiteDataStoreProvider = websiteDataStoreProvider
        self.fileRemover = fileRemover
        self.bundleIdentifier = bundleIdentifier
        self.defaultProfileDisplayName = defaultProfileDisplayName
        load()
    }

    /// Stable identifier of the immovable built-in default profile.
    public var builtInDefaultProfileID: UUID {
        Self.builtInDefaultProfileID
    }

    /// The last-used profile id if it still exists, else the built-in default.
    public var effectiveLastUsedProfileID: UUID {
        profileDefinition(id: lastUsedProfileID) != nil ? lastUsedProfileID : Self.builtInDefaultProfileID
    }

    /// Looks up a profile by id.
    /// - Parameter id: The profile id.
    /// - Returns: The matching definition, or `nil`.
    public func profileDefinition(id: UUID) -> BrowserProfileDefinition? {
        profiles.first(where: { $0.id == id })
    }

    /// Display name for a profile id, falling back to the default profile name.
    /// - Parameter id: The profile id.
    /// - Returns: The profile's display name, or the default name when unknown.
    public func displayName(for id: UUID) -> String {
        profileDefinition(id: id)?.displayName ?? defaultProfileDisplayName
    }

    /// Creates a new non-default profile, persists, and marks it used.
    /// - Parameter rawName: The requested name; trimmed of surrounding whitespace.
    /// - Returns: The created profile, or `nil` when the trimmed name is empty.
    public func createProfile(named rawName: String) -> BrowserProfileDefinition? {
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

    /// Renames a non-default profile and persists.
    /// - Parameters:
    ///   - id: The profile id.
    ///   - rawName: The new name; trimmed of surrounding whitespace.
    /// - Returns: `true` on success; `false` for an empty name, unknown id, or the built-in default.
    public func renameProfile(id: UUID, to rawName: String) -> Bool {
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

    /// Whether a profile can be renamed (i.e. exists and is not the built-in default).
    /// - Parameter id: The profile id.
    /// - Returns: `true` when renaming is allowed.
    public func canRenameProfile(id: UUID) -> Bool {
        guard let profile = profileDefinition(id: id) else { return false }
        return !profile.isBuiltInDefault
    }

    /// Deletes a non-default profile, tears down its stores, and removes its history directory.
    /// - Parameter id: The profile id.
    /// - Returns: The removed profile, or `nil` for an unknown id or the built-in default.
    public func deleteProfile(id: UUID) -> BrowserProfileDefinition? {
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
            let remover = fileRemover
            Task.detached(priority: .utility) {
                await remover.removeItemIfExists(at: historyDirectoryURL)
            }
        }
        return removed
    }

    /// Wipes one profile's website data and history.
    /// - Parameter id: The profile id.
    /// - Returns: A ``BrowserProfileClearOutcome`` describing what was cleared, or `nil` for an unknown id.
    public func clearProfileData(id: UUID) async -> BrowserProfileClearOutcome? {
        guard let profile = profileDefinition(id: id) else { return nil }
        let store = websiteDataStore(for: id)
        let historyURL = historyFileURL(for: id)
        historyStore(for: id).clearHistoryWithoutLoadingPersistedFile()
        let dataTypes = websiteDataStoreProvider.allWebsiteDataTypes
        await websiteDataStoreProvider.removeAllData(ofTypes: dataTypes, from: store)
        if let historyURL {
            await fileRemover.removeItemIfExists(at: historyURL)
        }
        return BrowserProfileClearOutcome(
            profile: profile,
            clearedWebsiteDataTypes: dataTypes.sorted(),
            clearedHistory: true
        )
    }

    /// Records a profile as last-used and persists the selection.
    /// - Parameter id: The profile id; ignored when unknown.
    public func noteUsed(_ id: UUID) {
        guard profileDefinition(id: id) != nil else { return }
        if lastUsedProfileID != id {
            lastUsedProfileID = id
            defaults.set(id.uuidString, forKey: Self.lastUsedProfileDefaultsKey)
        }
    }

    /// Returns the cached `WKWebsiteDataStore` handle for a profile, creating it on first use.
    /// - Parameter profileID: The profile id.
    /// - Returns: An opaque `WKWebsiteDataStore` handle (the default store for the built-in default profile).
    public func websiteDataStore(for profileID: UUID) -> AnyObject {
        if profileID == Self.builtInDefaultProfileID {
            return websiteDataStoreProvider.defaultWebsiteDataStore
        }
        if let existing = dataStores[profileID] {
            return existing
        }
        let store = websiteDataStoreProvider.makeWebsiteDataStore(forProfileID: profileID)
        dataStores[profileID] = store
        return store
    }

    /// Returns the cached history store for a profile, creating it on first use.
    /// - Parameter profileID: The profile id.
    /// - Returns: The shared history store for the built-in default, else a file-backed per-profile store.
    public func historyStore(for profileID: UUID) -> any BrowserProfileHistoryStore {
        if profileID == Self.builtInDefaultProfileID {
            return historyProvider.sharedHistoryStore
        }
        if let existing = historyStores[profileID] {
            return existing
        }
        let store = historyProvider.makeHistoryStore(fileURL: historyFileURL(for: profileID))
        historyStores[profileID] = store
        return store
    }

    /// The history file URL for a profile.
    /// - Parameter profileID: The profile id.
    /// - Returns: The built-in default's shared file for the default profile, else a per-profile
    ///   `…/<namespace>/browser_profiles/<uuid>/browser_history.json` URL, or `nil` if unresolvable.
    public func historyFileURL(for profileID: UUID) -> URL? {
        if profileID == Self.builtInDefaultProfileID {
            return historyProvider.defaultHistoryFileURLForCurrentBundle()
        }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let namespace = historyProvider.normalizedBrowserHistoryNamespace(forBundleIdentifier: bundleIdentifier)
        let profilesDir = appSupport
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("browser_profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        return profilesDir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    /// Flushes pending saves on the shared default history store and every cached per-profile store.
    public func flushPendingSaves() {
        historyProvider.flushSharedHistoryPendingSaves()
        for store in historyStores.values {
            store.flushPendingSaves()
        }
    }

    private func load() {
        let builtInDefaultProfile = BrowserProfileDefinition(
            id: Self.builtInDefaultProfileID,
            displayName: defaultProfileDisplayName,
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

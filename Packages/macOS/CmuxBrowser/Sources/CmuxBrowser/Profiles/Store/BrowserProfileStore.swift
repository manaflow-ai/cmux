public import Foundation
public import Combine
public import WebKit

/// Observable profile-selection model that the browser UI binds to.
///
/// A thin `ObservableObject` facade over ``BrowserProfileRepository``: it mirrors
/// the repository's `profiles` list and `lastUsedProfileID` selection into
/// `@Published` properties so SwiftUI views observing it via `@ObservedObject`
/// re-render on profile changes, and forwards every mutation to the repository
/// before re-mirroring. The repository owns all persistence; this type owns only
/// the published projection.
///
/// `@MainActor` because it seeds synchronously in `init` and is consumed by the
/// main-thread views; mirrors the original `@MainActor` store exactly.
///
/// The localized built-in-default display name is injected (`defaultProfileDisplayName`)
/// rather than resolved here so `String(localized:)` binds to the app bundle's
/// `.xcstrings` (the app's `BrowserProfileStore.shared` factory passes it).
@MainActor
public final class BrowserProfileStore: ObservableObject {
    /// The current profile list, default first then alphabetical by display name.
    @Published public private(set) var profiles: [BrowserProfileDefinition] = []
    /// The last-used profile id; defaults to the built-in default.
    @Published public private(set) var lastUsedProfileID: UUID = BrowserProfileRepository.builtInDefaultProfileID

    private let repository: BrowserProfileRepository

    /// Creates the store and synchronously loads persisted state.
    /// - Parameters:
    ///   - defaults: Backing `UserDefaults`.
    ///   - defaultProfileDisplayName: Localized display name for the built-in default profile;
    ///     resolve `String(localized:)` app-side and pass it in.
    public init(
        defaults: UserDefaults = .standard,
        defaultProfileDisplayName: String = "Default"
    ) {
        repository = BrowserProfileRepository(
            defaults: defaults,
            historyProvider: BrowserProfileHistoryAdapter(),
            websiteDataStoreProvider: BrowserProfileWebsiteDataStoreAdapter(),
            fileRemover: BrowserProfileFileRemover(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "cmux",
            defaultProfileDisplayName: defaultProfileDisplayName
        )
        mirrorPublishedState()
    }

    private func mirrorPublishedState() {
        profiles = repository.profiles
        lastUsedProfileID = repository.lastUsedProfileID
    }

    /// Stable identifier of the immovable built-in default profile.
    public var builtInDefaultProfileID: UUID {
        repository.builtInDefaultProfileID
    }

    /// The last-used profile id if it still exists, else the built-in default.
    public var effectiveLastUsedProfileID: UUID {
        repository.effectiveLastUsedProfileID
    }

    /// Looks up a profile by id.
    public func profileDefinition(id: UUID) -> BrowserProfileDefinition? {
        repository.profileDefinition(id: id)
    }

    /// Display name for a profile id, falling back to the default profile name.
    public func displayName(for id: UUID) -> String {
        repository.displayName(for: id)
    }

    /// Creates a new non-default profile, persists, and marks it used.
    public func createProfile(named rawName: String) -> BrowserProfileDefinition? {
        let result = repository.createProfile(named: rawName)
        mirrorPublishedState()
        return result
    }

    /// Renames a non-default profile and persists.
    public func renameProfile(id: UUID, to rawName: String) -> Bool {
        let result = repository.renameProfile(id: id, to: rawName)
        mirrorPublishedState()
        return result
    }

    /// Whether a profile can be renamed (i.e. exists and is not the built-in default).
    public func canRenameProfile(id: UUID) -> Bool {
        repository.canRenameProfile(id: id)
    }

    /// Deletes a non-default profile, tears down its stores, and removes its history directory.
    public func deleteProfile(id: UUID) -> BrowserProfileDefinition? {
        let result = repository.deleteProfile(id: id)
        mirrorPublishedState()
        return result
    }

    /// Wipes one profile's website data and history.
    public func clearProfileData(id: UUID) async -> BrowserProfileClearOutcome? {
        let result = await repository.clearProfileData(id: id)
        mirrorPublishedState()
        return result
    }

    /// Records a profile as last-used and persists the selection.
    public func noteUsed(_ id: UUID) {
        repository.noteUsed(id)
        mirrorPublishedState()
    }

    /// Returns the cached `WKWebsiteDataStore` handle for a profile, creating it on first use.
    public func websiteDataStore(for profileID: UUID) -> WKWebsiteDataStore {
        // Safe force-cast: the adapter only ever vends `WKWebsiteDataStore` handles.
        repository.websiteDataStore(for: profileID) as! WKWebsiteDataStore
    }

    /// Returns the cached history store for a profile, creating it on first use.
    public func historyStore(for profileID: UUID) -> BrowserHistoryStore {
        // Safe force-cast: the adapter only ever vends `BrowserHistoryStore` handles.
        repository.historyStore(for: profileID) as! BrowserHistoryStore
    }

    /// The history file URL for a profile.
    public func historyFileURL(for profileID: UUID) -> URL? {
        repository.historyFileURL(for: profileID)
    }

    /// Flushes pending saves on the shared default history store and every cached per-profile store.
    public func flushPendingSaves() {
        repository.flushPendingSaves()
    }
}

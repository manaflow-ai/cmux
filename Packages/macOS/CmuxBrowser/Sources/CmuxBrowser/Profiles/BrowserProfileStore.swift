public import Foundation
public import WebKit
import Observation

/// Adapts ``CmuxBrowser``'s `BrowserHistoryStore` to the profile-history seam so
/// the profile repository can manage per-profile history stores through the
/// ``BrowserProfileHistoryStore`` protocol.
///
/// The protocol's `@MainActor` lifecycle requirements are satisfied by the
/// store's existing public surface.
@MainActor
private final class BrowserProfileHistoryAdapter: BrowserProfileHistoryProviding {
    var sharedHistoryStore: any BrowserProfileHistoryStore { BrowserHistoryStore.shared }

    func makeHistoryStore(fileURL: URL?) -> any BrowserProfileHistoryStore {
        BrowserHistoryStore(fileURL: fileURL)
    }

    func defaultHistoryFileURLForCurrentBundle() -> URL? {
        BrowserHistoryStore.defaultHistoryFileURLForCurrentBundle()
    }

    func normalizedBrowserHistoryNamespace(forBundleIdentifier bundleIdentifier: String) -> String {
        BrowserHistoryStore.normalizedBrowserHistoryNamespaceForBundleIdentifier(bundleIdentifier)
    }

    func flushSharedHistoryPendingSaves() {
        BrowserHistoryStore.shared.flushPendingSaves()
    }
}

/// Adapts WebKit's `WKWebsiteDataStore` to the profile data-store seam, mapping
/// the built-in default profile to the default store and bridging the legacy
/// completion-handler wipe to `async`/`await` at this one boundary.
@MainActor
private final class BrowserProfileWebsiteDataStoreAdapter: BrowserProfileWebsiteDataStoreProviding {
    var defaultWebsiteDataStore: AnyObject { WKWebsiteDataStore.default() }

    func makeWebsiteDataStore(forProfileID profileID: UUID) -> AnyObject {
        WKWebsiteDataStore(forIdentifier: profileID)
    }

    var allWebsiteDataTypes: [String] { Array(WKWebsiteDataStore.allWebsiteDataTypes()) }

    func removeAllData(ofTypes dataTypes: [String], from store: AnyObject) async {
        guard let store = store as? WKWebsiteDataStore else { return }
        let types = Set(dataTypes)
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}

/// Removes profile-owned files via a detached utility task, matching the
/// original best-effort, ignore-errors deletion behavior.
private struct BrowserProfileFileRemover: BrowserProfileFileRemoving {
    func removeItemIfExists(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}

/// Observable facade over ``BrowserProfileRepository`` for SwiftUI and the
/// browser surfaces.
///
/// Vends the profile list and last-used selection and forwards
/// create/rename/delete/clear/note-used plus the per-profile
/// `WKWebsiteDataStore`/`BrowserHistoryStore` lookups, re-publishing the
/// repository's mirrored state after every mutation. The WebKit, filesystem, and
/// history concretes stay behind the repository's injected seams.
///
/// `@MainActor` because it seeds synchronously in `init` and is consumed by the
/// main thread and views.
///
/// The built-in default profile's display name must be localized in the *app*
/// bundle: `String(localized:)` resolved inside this package would bind to the
/// package bundle and drop non-English translations. The app composition point
/// sets ``defaultProfileDisplayNameProvider`` before ``shared`` is first
/// accessed; the `init` reads that provider so the kept `static let shared`
/// stays `BrowserProfileStore()` while the localized name still flows in.
@MainActor
@Observable
public final class BrowserProfileStore {
    /// Resolves the built-in default profile's localized display name.
    ///
    /// Defaults to the English fallback so the package builds and tests run
    /// without app wiring. The app composition point overrides this with a
    /// closure that calls `String(localized:)` against the app bundle before the
    /// ``shared`` singleton is first touched.
    public static var defaultProfileDisplayNameProvider: @MainActor () -> String = { "Default" }

    /// The process-wide profile store.
    ///
    /// Kept as a relocated singleton (faithful relocation, not
    /// de-singletonization), mirroring the sibling `BrowserHistoryStore.shared`.
    public static let shared = BrowserProfileStore()

    public private(set) var profiles: [BrowserProfileDefinition] = []
    public private(set) var lastUsedProfileID: UUID = BrowserProfileRepository.builtInDefaultProfileID

    private let repository: BrowserProfileRepository

    /// Creates the facade and its backing repository.
    /// - Parameters:
    ///   - defaults: Backing `UserDefaults`.
    ///   - defaultProfileDisplayName: Localized display name for the built-in
    ///     default profile, resolved app-side; defaults to the value from
    ///     ``defaultProfileDisplayNameProvider``.
    public init(
        defaults: UserDefaults = .standard,
        defaultProfileDisplayName: String = BrowserProfileStore.defaultProfileDisplayNameProvider()
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

    public var builtInDefaultProfileID: UUID {
        repository.builtInDefaultProfileID
    }

    public var effectiveLastUsedProfileID: UUID {
        repository.effectiveLastUsedProfileID
    }

    public func profileDefinition(id: UUID) -> BrowserProfileDefinition? {
        repository.profileDefinition(id: id)
    }

    public func displayName(for id: UUID) -> String {
        repository.displayName(for: id)
    }

    public func createProfile(named rawName: String) -> BrowserProfileDefinition? {
        let result = repository.createProfile(named: rawName)
        mirrorPublishedState()
        return result
    }

    public func renameProfile(id: UUID, to rawName: String) -> Bool {
        let result = repository.renameProfile(id: id, to: rawName)
        mirrorPublishedState()
        return result
    }

    public func canRenameProfile(id: UUID) -> Bool {
        repository.canRenameProfile(id: id)
    }

    public func deleteProfile(id: UUID) -> BrowserProfileDefinition? {
        let result = repository.deleteProfile(id: id)
        mirrorPublishedState()
        return result
    }

    public func clearProfileData(id: UUID) async -> BrowserProfileClearOutcome? {
        let result = await repository.clearProfileData(id: id)
        mirrorPublishedState()
        return result
    }

    public func noteUsed(_ id: UUID) {
        repository.noteUsed(id)
        mirrorPublishedState()
    }

    public func websiteDataStore(for profileID: UUID) -> WKWebsiteDataStore {
        // Safe force-cast: the adapter only ever vends `WKWebsiteDataStore` handles.
        repository.websiteDataStore(for: profileID) as! WKWebsiteDataStore
    }

    public func historyStore(for profileID: UUID) -> BrowserHistoryStore {
        // Safe force-cast: the adapter only ever vends `BrowserHistoryStore` handles.
        repository.historyStore(for: profileID) as! BrowserHistoryStore
    }

    public func historyFileURL(for profileID: UUID) -> URL? {
        repository.historyFileURL(for: profileID)
    }

    public func flushPendingSaves() {
        repository.flushPendingSaves()
    }
}

/// Adapts `BrowserHistoryStore` to the profile-history seam. Declared here, beside
/// the adapters that vend it, so the conformance lives with its related members.
extension BrowserHistoryStore: BrowserProfileHistoryStore {}

/// `BrowserProfileStore` already vends the profile list, id lookup, and create
/// operations plan realization needs, so it supplies the destination-profile
/// seam to `RealizedBrowserImportExecutionPlan.realized(from:profileResolver:)`.
extension BrowserProfileStore: BrowserImportProfileResolving {}

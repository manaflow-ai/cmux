import Foundation
import WebKit

/// Tracks only live, isolated WebKit stores that received cmux app-session
/// cookies. Older releases persisted shared profile identifiers; initialization
/// retires those markers without reopening profiles that may now belong to a
/// different web account.
@MainActor
final class BrowserAppSessionStoreRegistry {
    private let environment: BrowserAppSessionEnvironment
    private var liveStores: [
        ObjectIdentifier: BrowserAppSessionWeakReference<WKWebsiteDataStore>
    ] = [:]
    private var livePanels: [
        ObjectIdentifier: BrowserAppSessionWeakReference<BrowserPanel>
    ] = [:]

    init(
        defaults: UserDefaults,
        defaultsKey: String,
        environment: BrowserAppSessionEnvironment,
        legacyDefaultsKeyPrefix: String? = nil
    ) {
        self.environment = environment
        defaults.removeObject(forKey: defaultsKey)
        if let legacyDefaultsKeyPrefix {
            for key in Self.legacyDefaultsKeys(
                defaults: defaults,
                prefix: legacyDefaultsKeyPrefix,
                excluding: defaultsKey
            ) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func register(_ store: WKWebsiteDataStore) {
        // Credential handoffs must use a dedicated non-persistent store. Never
        // claim or later sweep a user's shared persistent browser profile.
        guard store !== WKWebsiteDataStore.default(), store.identifier == nil else {
            return
        }
        liveStores = liveStores.filter { $0.value.value != nil }
        liveStores[ObjectIdentifier(store)] = BrowserAppSessionWeakReference(store)
    }

    func register(_ panel: BrowserPanel) {
        pruneReleasedOwnership()
        guard liveStores[ObjectIdentifier(panel.websiteDataStore)]?.value != nil else {
            return
        }
        livePanels[ObjectIdentifier(panel)] = BrowserAppSessionWeakReference(panel)
    }

    var hasOwnership: Bool {
        pruneReleasedOwnership()
        return !liveStores.isEmpty || !livePanels.isEmpty
    }

    func panelsForCleanup() -> [BrowserPanel] {
        pruneReleasedOwnership()
        return livePanels.values.compactMap(\.value).filter {
            liveStores[ObjectIdentifier($0.websiteDataStore)]?.value != nil
        }
    }

    func storesForCleanup() -> [WKWebsiteDataStore] {
        var stores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
        for target in allEnvironmentStoresForCleanup() {
            stores[ObjectIdentifier(target.store)] = target.store
        }
        return Array(stores.values)
    }

    func allEnvironmentStoresForCleanup() -> [BrowserAppSessionStoreCleanupTarget] {
        pruneReleasedOwnership()
        var targets: [ObjectIdentifier: BrowserAppSessionStoreCleanupTarget] = [:]
        for (identifier, reference) in liveStores {
            if let store = reference.value {
                targets[identifier] = BrowserAppSessionStoreCleanupTarget(
                    store: store,
                    environment: environment
                )
            }
        }
        return Array(targets.values)
    }

    func removeAllOwnership() {
        liveStores.removeAll()
        livePanels.removeAll()
    }

    private func pruneReleasedOwnership() {
        liveStores = liveStores.filter { $0.value.value != nil }
        livePanels = livePanels.filter { $0.value.value != nil }
    }

    private static func legacyDefaultsKeys(
        defaults: UserDefaults,
        prefix: String,
        excluding currentKey: String
    ) -> [String] {
        defaults.dictionaryRepresentation().keys.filter {
            $0 != currentKey && $0.hasPrefix(prefix) && $0.count > prefix.count
        }
    }
}

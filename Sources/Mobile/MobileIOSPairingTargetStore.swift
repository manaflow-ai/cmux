import CmuxCloud
import CMUXMobileCore
import Foundation

/// Persists the iOS app used when rendering a legacy pairing URL.
@MainActor
struct MobileIOSPairingTargetStore {
    static let defaultsKey = "mobile.pairing.targetIOSBundleIdentifier"

    private let defaults: UserDefaults
    private let macInstanceTag: String

    init(
        defaults: UserDefaults = .standard,
        macInstanceTag: String = MobileHostIdentity.instanceTag()
    ) {
        self.defaults = defaults
        self.macInstanceTag = macInstanceTag
    }

    var availableNamespaces: [MobileIOSAppNamespace] {
        if !isOfficialMacLane {
            return [
                MobileIOSAppNamespace(
                    pairedMacInstanceTag: macInstanceTag
                ),
            ].compactMap { $0 }
        }
        return [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ].compactMap(MobileIOSAppNamespace.init(bundleIdentifier:))
    }

    var selectedNamespace: MobileIOSAppNamespace? {
        let available = availableNamespaces
        return storedNamespace(in: available) ?? available.first
    }

    var selectedPairingURLScheme: CmxPairingURLScheme? {
        guard let selectedNamespace else { return nil }
        return CmxPairingURLScheme(
            iOSBundleIdentifier: selectedNamespace.bundleIdentifier
        )
    }

    @discardableResult
    func select(_ namespace: MobileIOSAppNamespace) -> Bool {
        guard availableNamespaces.contains(namespace) else { return false }
        defaults.set(namespace.bundleIdentifier, forKey: Self.defaultsKey)
        return true
    }

    private var isOfficialMacLane: Bool {
        switch macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "default", "nightly", "rc":
            true
        default:
            false
        }
    }

    private func storedNamespace(
        in available: [MobileIOSAppNamespace]
    ) -> MobileIOSAppNamespace? {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let namespace = MobileIOSAppNamespace(
                  bundleIdentifier: stored
              ),
              available.contains(namespace) else {
            return nil
        }
        return namespace
    }
}

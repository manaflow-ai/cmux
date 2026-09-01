import CMUXMobileCore

/// One exact installed iOS app the Mac can target with its QR scheme.
struct MobileIOSAppTarget: Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }

    var pairingURLScheme: CmxPairingURLScheme? {
        CmxPairingURLScheme(iOSBundleIdentifier: bundleIdentifier)
    }
}

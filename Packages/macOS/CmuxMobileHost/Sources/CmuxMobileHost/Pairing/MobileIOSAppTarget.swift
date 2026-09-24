public import CMUXMobileCore

/// One exact installed iOS app the Mac can target with its QR scheme.
public struct MobileIOSAppTarget: Equatable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public var id: String { bundleIdentifier }

    public var pairingURLScheme: CmxPairingURLScheme? {
        CmxPairingURLScheme(iOSBundleIdentifier: bundleIdentifier)
    }
}

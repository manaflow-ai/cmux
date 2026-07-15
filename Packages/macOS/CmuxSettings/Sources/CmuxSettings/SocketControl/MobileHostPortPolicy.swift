import Foundation

/// Pure policy for the Mac-side mobile pairing host's preferred TCP port.
public enum MobileHostPortPolicy {
    public static let validPortRange: ClosedRange<Int> = 1...65_535
    public static let taggedDevelopmentPortRange: ClosedRange<Int> = 49_152...65_535

    /// Returns the preferred port for the mobile host listener.
    ///
    /// A valid explicit setting wins. When unset or invalid, tagged DEBUG builds
    /// derive a stable port from ``SocketControlSettings/launchTag(environment:)``;
    /// release and untagged builds use the catalog default.
    public static func configuredPort(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let catalogPort = SettingCatalog().mobile.iOSPairingPort
        let fallback = defaultConfiguredPort(
            environment: environment,
            catalogDefaultPort: catalogPort.defaultValue
        )
        guard let raw = defaults.object(forKey: catalogPort.userDefaultsKey) as? Int else {
            return fallback
        }
        return validPortRange.contains(raw) ? raw : fallback
    }

    /// Returns the desired listener port, or `nil` when a stored explicit value is
    /// present but invalid and should not disturb a running listener.
    public static func resolvedDesiredPort(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        let catalogPort = SettingCatalog().mobile.iOSPairingPort
        guard let raw = defaults.object(forKey: catalogPort.userDefaultsKey) as? Int else {
            return defaultConfiguredPort(
                environment: environment,
                catalogDefaultPort: catalogPort.defaultValue
            )
        }
        return validPortRange.contains(raw) ? raw : nil
    }

    public static func defaultConfiguredPort(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        catalogDefaultPort: Int = SettingCatalog().mobile.iOSPairingPort.defaultValue
    ) -> Int {
        #if DEBUG
        if let port = taggedDevelopmentDefaultPort(
            environment: environment,
            catalogDefaultPort: catalogDefaultPort
        ) {
            return port
        }
        #endif
        return catalogDefaultPort
    }

    #if DEBUG
    private static func taggedDevelopmentDefaultPort(
        environment: [String: String],
        catalogDefaultPort: Int
    ) -> Int? {
        guard let tag = SocketControlSettings.launchTag(environment: environment) else {
            return nil
        }
        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTag.isEmpty, normalizedTag != "default" else { return nil }

        var hash: UInt32 = 2_166_136_261
        for byte in normalizedTag.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }

        let lowerBound = taggedDevelopmentPortRange.lowerBound
        let upperBound = taggedDevelopmentPortRange.upperBound
        let portCount = upperBound - lowerBound + 1
        var port = lowerBound + Int(hash % UInt32(portCount))
        if port == catalogDefaultPort {
            port = lowerBound + ((port - lowerBound + 1) % portCount)
        }
        return port
    }
    #endif
}

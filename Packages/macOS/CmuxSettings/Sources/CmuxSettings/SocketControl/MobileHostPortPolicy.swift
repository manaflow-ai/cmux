import Foundation

/// Pure policy for the Mac-side mobile pairing host's preferred TCP port.
public struct MobileHostPortPolicy: Sendable {
    /// Inclusive TCP port range accepted by the mobile-host setting.
    public static let validPortRange: ClosedRange<Int> = 1...65_535

    /// Dynamic/private TCP port range used for deterministic tagged DEBUG defaults.
    public static let taggedDevelopmentPortRange: ClosedRange<Int> = 49_152...65_535

    private let portDefaultsKey: String
    private let catalogDefaultPort: Int

    /// Creates a policy for the supplied settings key and catalog default.
    public init(
        portDefaultsKey: String = SettingCatalog().mobile.iOSPairingPort.userDefaultsKey,
        catalogDefaultPort: Int = SettingCatalog().mobile.iOSPairingPort.defaultValue
    ) {
        self.portDefaultsKey = portDefaultsKey
        self.catalogDefaultPort = catalogDefaultPort
    }

    /// Returns the preferred port for the mobile host listener.
    ///
    /// A valid explicit setting wins. When unset or invalid, tagged DEBUG builds
    /// derive a stable port from ``SocketControlSettings/launchTag(environment:)``;
    /// release and untagged builds use the catalog default.
    public func configuredPort(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let fallback = defaultConfiguredPort(
            environment: environment,
            catalogDefaultPort: catalogDefaultPort
        )
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return fallback
        }
        return Self.validPortRange.contains(raw) ? raw : fallback
    }

    /// Returns the desired listener port, or `nil` when a stored explicit value is
    /// present but invalid and should not disturb a running listener.
    public func resolvedDesiredPort(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return defaultConfiguredPort(
                environment: environment,
                catalogDefaultPort: catalogDefaultPort
            )
        }
        return Self.validPortRange.contains(raw) ? raw : nil
    }

    /// Returns the fallback port for unset or invalid settings.
    public func defaultConfiguredPort(
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
    private func taggedDevelopmentDefaultPort(
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

        let lowerBound = Self.taggedDevelopmentPortRange.lowerBound
        let upperBound = Self.taggedDevelopmentPortRange.upperBound
        let portCount = upperBound - lowerBound + 1
        var port = lowerBound + Int(hash % UInt32(portCount))
        if port == catalogDefaultPort {
            port = lowerBound + ((port - lowerBound + 1) % portCount)
        }
        return port
    }
    #endif
}

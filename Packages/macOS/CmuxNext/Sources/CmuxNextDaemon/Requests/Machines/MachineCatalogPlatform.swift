import Foundation

/// Non-secret OS and architecture observed from a machine owner; absent fields stay unknown.
public nonisolated struct MachineCatalogPlatform: Codable, Sendable, Hashable {
    /// The owner's OS token, such as `linux` or `macos`; never the client's OS.
    public let os: String?
    /// The owner's architecture token, if observed.
    public let arch: String?

    /// Captures observed tokens without substituting a local platform.
    /// - Parameters:
    ///   - os: The owner's optional OS token.
    ///   - arch: The owner's optional architecture token.
    public init(os: String? = nil, arch: String? = nil) { self.os = os; self.arch = arch }

    /// Bounded tokens suitable for the catalog; invalid or empty tokens remain unknown.
    package var bounded: Self? {
        let os = os.flatMap { Self.token($0) ? $0 : nil }
        let arch = arch.flatMap { Self.token($0) ? $0 : nil }
        return os == nil && arch == nil ? nil : Self(os: os, arch: arch)
    }

    private static func token(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte)
        }
    }
}

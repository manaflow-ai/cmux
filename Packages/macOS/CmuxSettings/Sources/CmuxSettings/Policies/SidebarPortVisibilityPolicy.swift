/// Filters raw listening-port observations for publication to sidebar consumers.
public struct SidebarPortVisibilityPolicy: Sendable, Equatable {
    /// The IANA dynamic/private range used for OS-assigned ephemeral ports.
    public static let operatingSystemEphemeralRange = 49_152...65_535

    /// The ignored rules used when the user has not supplied an override.
    public static let defaultIgnoredRules: [SidebarIgnoredPortRule] = [
        .range(operatingSystemEphemeralRange),
    ]

    private let ignoredRules: [SidebarIgnoredPortRule]

    /// Creates a sidebar port policy from the user's complete ignored-rules override.
    ///
    /// - Parameter ignoredRules: Exact ports and inclusive ranges to omit.
    public init(
        ignoredRules: [SidebarIgnoredPortRule] = SidebarPortVisibilityPolicy.defaultIgnoredRules
    ) {
        self.ignoredRules = ignoredRules
    }

    /// Removes ignored ports while preserving the input order and duplicates.
    ///
    /// - Parameter ports: Raw listening ports collected for a workspace.
    /// - Returns: Ports eligible for sidebar publication.
    public func visiblePorts(from ports: [Int]) -> [Int] {
        ports.filter { port in
            !ignoredRules.contains { $0.contains(port) }
        }
    }
}

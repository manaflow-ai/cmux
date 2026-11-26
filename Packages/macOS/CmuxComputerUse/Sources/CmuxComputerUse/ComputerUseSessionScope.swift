import Foundation

/// Stable driver-session identity for one live cmux agent surface.
public struct ComputerUseSessionScope: Sendable {
    /// The id exposed to the host application.
    public let id: String
    /// The driver session id exposed to the host application.
    public let driverSessionID: String

    /// Creates the same scope previously provided by the memberwise initializer.
    /// - Parameters:
    ///   - id: The host's live surface row identifier.
    ///   - driverSessionID: The standalone driver's stable session identifier.
    public init(id: String, driverSessionID: String) {
        self.id = id
        self.driverSessionID = driverSessionID
    }

    /// The driver session id exposed to the host application.
    public static func driverSessionID(surfaceID: UUID) -> String {
        "cmux-\(surfaceID.uuidString)"
    }

    /// The is managed driver session id exposed to the host application.
    public static func isManagedDriverSessionID(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("cmux-") else { return false }
        return UUID(uuidString: String(candidate.dropFirst("cmux-".count))) != nil
    }

    /// The driver session id exposed to the host application.
    public static func driverSessionID(containing candidate: String) -> String? {
        if isManagedDriverSessionID(candidate) {
            return candidate
        }
        guard let marker = candidate.range(of: "-mcp-") else { return nil }
        let driverSessionID = String(candidate[..<marker.lowerBound])
        return isManagedProxySessionID(candidate, for: driverSessionID)
            ? driverSessionID
            : nil
    }

    /// Accepts the stable forced-proxy session or one of its managed child generations.
    public static func isManagedProxySessionID(
        _ candidate: String,
        for driverSessionID: String
    ) -> Bool {
        guard isManagedDriverSessionID(driverSessionID) else { return false }
        if candidate == driverSessionID {
            return true
        }
        let prefix = "\(driverSessionID)-mcp-"
        return candidate.hasPrefix(prefix) && candidate.count > prefix.count
    }

    /// The matches exposed to the host application.
    public func matches(driverSessionID candidate: String?) -> Bool {
        guard let candidate else { return false }
        return candidate == driverSessionID
            || candidate.hasPrefix("\(driverSessionID)-mcp-")
    }
}

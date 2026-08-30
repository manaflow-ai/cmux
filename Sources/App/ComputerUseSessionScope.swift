import Foundation

/// Stable driver-session identity for one live cmux agent surface.
struct ComputerUseSessionScope: Sendable {
    let id: String
    let driverSessionID: String

    static func driverSessionID(surfaceID: UUID) -> String {
        "cmux-\(surfaceID.uuidString)"
    }

    static func isManagedDriverSessionID(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("cmux-") else { return false }
        return UUID(uuidString: String(candidate.dropFirst("cmux-".count))) != nil
    }

    static func driverSessionID(containing candidate: String) -> String? {
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
    static func isManagedProxySessionID(
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

    func matches(driverSessionID candidate: String?) -> Bool {
        guard let candidate else { return false }
        return candidate == driverSessionID
            || candidate.hasPrefix("\(driverSessionID)-mcp-")
    }
}

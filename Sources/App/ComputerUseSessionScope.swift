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

    func matches(driverSessionID candidate: String?) -> Bool {
        guard let candidate else { return false }
        return candidate == driverSessionID
            || candidate.hasPrefix("\(driverSessionID)-mcp-")
    }
}

import Foundation

/// Origin information supplied by the terminal `open` wrapper.
struct BrowserOpenEnvironment {
    nonisolated let environment: [String: String]

    nonisolated var isTerminalLink: Bool { Self.isTruthy(environment["CMUX_TERMINAL_LINK"]) }
    nonisolated var sourceSurfaceID: String? { environment["CMUX_SURFACE_ID"] }
    nonisolated var respectsExternalOpenRules: Bool { Self.isTruthy(environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"]) }

    nonisolated private static func isTruthy(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        return ["1", "true", "yes", "on"].contains(
            rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

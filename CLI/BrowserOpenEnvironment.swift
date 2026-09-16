import Foundation

/// Origin information supplied by the terminal `open` wrapper.
struct BrowserOpenEnvironment {
    let environment: [String: String]

    var isTerminalLink: Bool { environment["CMUX_TERMINAL_LINK"] == "1" }
    var sourceSurfaceID: String? { environment["CMUX_SURFACE_ID"] }
    var respectsExternalOpenRules: Bool {
        guard let raw = environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"] else { return false }
        return ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

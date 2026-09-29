import Foundation

/// Launch environment written into `LSEnvironment` by `scripts/reload.sh`
/// for tagged builds. Untagged runs leave every field nil.
struct AppEnvironment: Sendable {
    let tag: String?
    let bundleID: String?
    let socketPath: String?
    let socketEnabled: Bool
    /// `CMUX_NEXT_NO_ACTIVATE=1`: never take focus from the user's frontmost
    /// app (agent preflights and background launches).
    let noActivate: Bool

    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        AppEnvironment(
            tag: environment["CMUX_TAG"].flatMap { $0.isEmpty ? nil : $0 },
            bundleID: environment["CMUX_BUNDLE_ID"],
            socketPath: environment["CMUX_SOCKET_PATH"],
            socketEnabled: environment["CMUX_SOCKET_ENABLE"] == "1",
            noActivate: environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        )
    }
}

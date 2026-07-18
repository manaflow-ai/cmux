import Darwin
import Foundation

/// Filesystem paths shared by the app-owned Computer Use runtime and agent wrappers.
struct ComputerUseRuntimePaths: Sendable {
    static let daemonSocketEnvironmentKey = "CMUX_CUA_SOCKET_PATH"
    static let stateDirectoryEnvironmentKey = "CMUX_CUA_STATE_DIR"

    let scope: String
    let computerUseDirectoryURL: URL
    let runtimeDirectoryURL: URL
    let daemonSocketURL: URL
    let stateDirectoryURL: URL
    let installedHelperDirectoryURL: URL
    let installedHelperAppURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        socketRootDirectoryURL: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
        userIdentifier: uid_t = getuid(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        scope = Self.sanitizedScope(environment["CMUX_TAG"])
        computerUseDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/cmux/computer-use", isDirectory: true)
        runtimeDirectoryURL = socketRootDirectoryURL
            .appendingPathComponent("cmux-cua-\(userIdentifier)", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
        daemonSocketURL = runtimeDirectoryURL.appendingPathComponent("cua.sock")
        stateDirectoryURL = computerUseDirectoryURL
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        installedHelperDirectoryURL = computerUseDirectoryURL
            .appendingPathComponent("helper", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
        installedHelperAppURL = installedHelperDirectoryURL
            .appendingPathComponent("cmux Computer Use.app", isDirectory: true)
    }

    private static func sanitizedScope(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "default" }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        let scalars = rawValue.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return candidate.isEmpty ? "default" : String(candidate.prefix(64))
    }
}

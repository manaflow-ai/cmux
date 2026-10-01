public import Foundation

/// Where the app's acpmux lives and how it runs: the binary, a home of its
/// own per cmux build (so release, nightly and every dev tag run separate
/// daemons), and a short socket path.
public struct AcpmuxLaunchConfiguration: Sendable, Equatable {
    /// The acpmux executable.
    public var binary: URL
    /// `ACPMUX_HOME`: config, logs, sessions and attachments for this build.
    public var home: URL
    /// The daemon's Unix socket.
    public var socketPath: String
    /// The daemon's environment.
    public var environment: [String: String]

    /// Environment variable that points at a locally built acpmux.
    public static let binaryOverrideKey = "CMUX_NEXT_ACPMUX_BIN"

    /// Creates a configuration.
    /// - Parameters:
    ///   - binary: The executable.
    ///   - home: `ACPMUX_HOME`.
    ///   - socketPath: The socket path.
    ///   - environment: The daemon's environment.
    public init(binary: URL, home: URL, socketPath: String, environment: [String: String]) {
        self.binary = binary
        self.home = home
        self.socketPath = socketPath
        self.environment = environment
    }

    /// The configuration the app uses: the bundled binary (or
    /// `CMUX_NEXT_ACPMUX_BIN`), a home under Application Support per tag, a
    /// socket in `/tmp` short enough for `sockaddr_un`, and acpmux importing
    /// the login shell's environment (the app starts with launchd's).
    /// - Parameters:
    ///   - tag: The build's tag, or nil for release.
    ///   - bundle: The app bundle.
    ///   - processEnvironment: The app's environment.
    ///   - applicationSupport: The user's Application Support directory.
    /// - Returns: The configuration, or nil when no binary exists.
    public static func forApp(tag: String?, bundle: Bundle, processEnvironment: [String: String], applicationSupport: URL) -> AcpmuxLaunchConfiguration? {
        let fm = FileManager.default
        var binary: URL?
        if let override = processEnvironment[binaryOverrideKey], !override.isEmpty, fm.isExecutableFile(atPath: override) {
            binary = URL(fileURLWithPath: override)
        } else if let bundled = bundle.resourceURL?.appendingPathComponent("bin/acpmux"), fm.isExecutableFile(atPath: bundled.path) {
            binary = bundled
        }
        guard let binary else { return nil }
        let component = sanitized(tag)
        let home = applicationSupport.appendingPathComponent(component.map { "cmux/tags/\($0)/acpmux" } ?? "cmux/acpmux", isDirectory: true)
        let socket = "/tmp/cmux-acpmux-\(getuid())-\(component ?? "release").sock"
        var environment = processEnvironment
        environment["ACPMUX_HOME"] = home.path
        environment["ACPMUX_SOCKET"] = socket
        environment["ACPMUX_LOGIN_ENV"] = "1"
        // An inherited tag must not leak into agents' shells as this build's.
        environment[binaryOverrideKey] = nil
        return AcpmuxLaunchConfiguration(binary: binary, home: home, socketPath: socket, environment: environment)
    }

    /// The tag reduced to a safe path component, or nil for release.
    static func sanitized(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(tag.prefix(40).map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The daemon's arguments: tied to this app's process, Unix socket only.
    /// - Parameter parentPID: The app's process id.
    /// - Returns: The arguments.
    public func arguments(parentPID: Int32) -> [String] {
        ["daemon", "run", "--exit-with-parent", String(parentPID), "--no-web"]
    }
}

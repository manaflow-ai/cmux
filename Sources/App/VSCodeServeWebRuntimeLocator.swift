import Foundation

enum VSCodeServeWebRuntimeLocator {
    /// Override the serve-web server data directory (absolute path).
    static let serverDataDirectoryEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_DATA_DIR"
    /// Override the stable serve-web port.
    static let portEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_PORT"
    /// VS Code CLI data dir env var; honored as-is when already set.
    static let cliDataDirectoryEnvironmentKey = "VSCODE_CLI_DATA_DIR"
    /// UserDefaults key the resolved default port is persisted under.
    static let portUserDefaultsKey = "vscodeServeWeb.port"

    /// IANA dynamic/private port range (49152–65535) avoids well-known and
    /// registered ports while still giving every bundle a stable default.
    private static let minimumPort = 49152
    private static let portRangeSize = 16384

    static func resolve(
        applicationSupportURL: URL,
        bundleIdentifier: String,
        environment: [String: String],
        persistedPort: Int?
    ) -> VSCodeServeWebRuntimeLocation {
        let serverDataDirectoryURL = resolveServerDataDirectoryURL(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
        let userDataDirectoryURL = serverDataDirectoryURL
            .appendingPathComponent("user-data", isDirectory: true)
        let cliDataDirectory = resolveCLIDataDirectory(
            serverDataDirectoryURL: serverDataDirectoryURL,
            environment: environment
        )
        let connectionTokenFileURL = serverDataDirectoryURL
            .appendingPathComponent("connection-token", isDirectory: false)
        let port = resolvePort(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            persistedPort: persistedPort
        )

        return VSCodeServeWebRuntimeLocation(
            serverDataDirectoryURL: serverDataDirectoryURL,
            userDataDirectoryURL: userDataDirectoryURL,
            cliDataDirectoryURL: cliDataDirectory.url,
            cliDataDirectoryIsExternal: cliDataDirectory.isExternal,
            connectionTokenFileURL: connectionTokenFileURL,
            port: port
        )
    }

    private static func resolveServerDataDirectoryURL(
        applicationSupportURL: URL,
        bundleIdentifier: String,
        environment: [String: String]
    ) -> URL {
        if let override = environment[serverDataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("vscode-serve-web", isDirectory: true)
    }

    private static func resolveCLIDataDirectory(
        serverDataDirectoryURL: URL,
        environment: [String: String]
    ) -> (url: URL, isExternal: Bool) {
        if let override = environment[cliDataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (URL(fileURLWithPath: override, isDirectory: true), true)
        }
        return (serverDataDirectoryURL.appendingPathComponent("cli-data", isDirectory: true), false)
    }

    /// Resolves the preferred serve-web port to try first: an explicit env
    /// override, else the last successfully-bound port persisted by the
    /// controller, else a deterministic per-bundle default.
    private static func resolvePort(
        bundleIdentifier: String,
        environment: [String: String],
        persistedPort: Int?
    ) -> Int {
        if let override = environment[portEnvironmentKey], let parsed = parsePort(override) {
            return parsed
        }
        if let persistedPort, isValidPort(persistedPort) {
            return persistedPort
        }
        return derivePort(from: bundleIdentifier)
    }

    /// Ordered ports to attempt for a launch: the preferred port first, then
    /// deterministic STABLE alternates within the dynamic/private range. This is
    /// what keeps the server origin fixed across launches even when the preferred
    /// port is occupied — falling back to an ephemeral port would change the
    /// origin every launch and reintroduce the auth/Settings Sync loss (#6595).
    /// The controller appends an ephemeral port only as a final last resort and
    /// persists whichever stable port actually binds.
    static func candidateStablePorts(resolvedPort: Int, count: Int = 8) -> [Int] {
        var ports: [Int] = [resolvedPort]
        var seen: Set<Int> = [resolvedPort]
        // Normalize the offset to 0..<portRangeSize so an out-of-range override
        // such as a user-set 3000 still yields in-range alternates after the first.
        let baseOffset = ((resolvedPort - minimumPort) % portRangeSize + portRangeSize) % portRangeSize
        var step = 1
        while ports.count < count && step <= portRangeSize {
            let port = minimumPort + (baseOffset + step) % portRangeSize
            step += 1
            if seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    static func parsePort(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), isValidPort(value) else { return nil }
        return value
    }

    static func isValidPort(_ port: Int) -> Bool {
        (1024...65535).contains(port)
    }

    /// Deterministic per-bundle default so different (e.g. tagged) builds get
    /// distinct, stable ports instead of colliding on one fixed value.
    static func derivePort(from bundleIdentifier: String) -> Int {
        var hash: UInt64 = 1469598103934665603 // FNV-1a 64-bit offset basis
        for byte in bundleIdentifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211 // FNV-1a 64-bit prime
        }
        return minimumPort + Int(hash % UInt64(portRangeSize))
    }
}

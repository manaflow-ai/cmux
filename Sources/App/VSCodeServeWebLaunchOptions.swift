import Darwin
import Foundation
import os

nonisolated private let vscodeServeWebLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "vscode.serve-web"
)

nonisolated struct VSCodeServeWebLaunchOptions: Equatable {
    static let portEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_PORT"
    static let dataDirectoryEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_DATA_DIR"
    static let portDefaultsKey = "vscodeServeWeb.port"

    let port: Int
    let serverDataDirectoryURL: URL
    let userDataDirectoryURL: URL
    let connectionTokenFileURL: URL
    let allowsEphemeralPortFallback: Bool

    var arguments: [String] {
        arguments(includeUserDataDirectory: true)
    }

    func arguments(includeUserDataDirectory: Bool) -> [String] {
        var arguments = [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--server-data-dir", serverDataDirectoryURL.path,
        ]
        if includeUserDataDirectory {
            arguments.append(contentsOf: ["--user-data-dir", userDataDirectoryURL.path])
        }
        arguments.append(contentsOf: [
            "--connection-token-file", connectionTokenFileURL.path,
        ])
        return arguments
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        applicationSupportDirectoryURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> VSCodeServeWebLaunchOptions? {
        guard let serverDataDirectoryURL = resolveServerDataDirectoryURL(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
        ) else { return nil }
        let userDataDirectoryURL = serverDataDirectoryURL.appendingPathComponent("user-data", isDirectory: true)

        do {
            try createSecureDirectory(serverDataDirectoryURL, fileManager: fileManager)
            try createSecureDirectory(userDataDirectoryURL, fileManager: fileManager)
        } catch {
            vscodeServeWebLogger.error(
                "Failed to create VS Code serve-web directories: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }

        guard let connectionTokenFileURL = ensureConnectionTokenFile(
            in: serverDataDirectoryURL,
            fileManager: fileManager
        ) else { return nil }

        let portResolution = resolvePort(
            environment: environment,
            defaults: defaults,
            bundleIdentifier: bundleIdentifier
        )

        return VSCodeServeWebLaunchOptions(
            port: portResolution.port,
            serverDataDirectoryURL: serverDataDirectoryURL,
            userDataDirectoryURL: userDataDirectoryURL,
            connectionTokenFileURL: connectionTokenFileURL,
            allowsEphemeralPortFallback: portResolution.allowsEphemeralFallback
        )
    }

    func ephemeralPortFallback() -> VSCodeServeWebLaunchOptions? {
        guard allowsEphemeralPortFallback else { return nil }
        return VSCodeServeWebLaunchOptions(
            port: 0,
            serverDataDirectoryURL: serverDataDirectoryURL,
            userDataDirectoryURL: userDataDirectoryURL,
            connectionTokenFileURL: connectionTokenFileURL,
            allowsEphemeralPortFallback: false
        )
    }

    private static func createSecureDirectory(_ url: URL, fileManager: FileManager) throws {
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
        ]
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private static func resolveServerDataDirectoryURL(
        environment: [String: String],
        bundleIdentifier: String?,
        applicationSupportDirectoryURL: URL?
    ) -> URL? {
        if let rawPath = environment[dataDirectoryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            return URL(fileURLWithPath: expandedHomePath(rawPath), isDirectory: true)
        }

        guard let applicationSupportDirectoryURL else { return nil }
        let namespace = normalizedNamespace(bundleIdentifier)
        return applicationSupportDirectoryURL
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("vscode-serve-web", isDirectory: true)
    }

    private static func resolvePort(
        environment: [String: String],
        defaults: UserDefaults,
        bundleIdentifier: String?
    ) -> (port: Int, allowsEphemeralFallback: Bool) {
        if let rawPort = environment[portEnvironmentKey],
           let port = Int(rawPort),
           isValidPort(port) {
            return (port, false)
        }

        let storedPort = defaults.integer(forKey: portDefaultsKey)
        if isValidPort(storedPort) {
            return (storedPort, true)
        }

        let port = defaultStablePort(bundleIdentifier)
        defaults.set(port, forKey: portDefaultsKey)
        return (port, true)
    }

    private static func defaultStablePort(_ bundleIdentifier: String?) -> Int {
        let identifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "cmux"
        let dynamicPortStart = 49152
        let dynamicPortCount = 16384
        let offset = identifier.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) % dynamicPortCount
        }
        return dynamicPortStart + offset
    }

    private static func isValidPort(_ port: Int) -> Bool {
        port > 0 && port <= 65535
    }

    private static func ensureConnectionTokenFile(
        in serverDataDirectoryURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let tokenFileURL = serverDataDirectoryURL.appendingPathComponent(
            "connection-token",
            isDirectory: false
        )
        // serve-web URLs include this token, and cmux restores those URLs across
        // app relaunches. Keep the token stable; loopback binding plus 0700/0600
        // filesystem permissions are the intended local security boundary.
        if fileManager.fileExists(atPath: tokenFileURL.path) {
            if isUsableConnectionTokenFile(tokenFileURL, fileManager: fileManager) {
                return tokenFileURL
            }
            try? fileManager.removeItem(at: tokenFileURL)
        }

        let token = randomConnectionToken()
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if fileDescriptor < 0 {
            return fileManager.fileExists(atPath: tokenFileURL.path)
                && isUsableConnectionTokenFile(tokenFileURL, fileManager: fileManager)
                ? tokenFileURL
                : nil
        }
        var shouldCloseFileDescriptor = true
        defer {
            if shouldCloseFileDescriptor {
                _ = close(fileDescriptor)
            }
        }

        guard fchmod(fileDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? fileManager.removeItem(at: tokenFileURL)
            return nil
        }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            try? fileManager.removeItem(at: tokenFileURL)
            return nil
        }

        shouldCloseFileDescriptor = false
        guard close(fileDescriptor) == 0,
              isUsableConnectionTokenFile(tokenFileURL, fileManager: fileManager) else {
            try? fileManager.removeItem(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func usableConnectionToken(
        _ tokenFileURL: URL,
        fileManager: FileManager
    ) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: tokenFileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value == 32,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            return nil
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: tokenFileURL) else {
            return nil
        }
        defer {
            try? fileHandle.close()
        }

        guard let data = try? fileHandle.read(upToCount: 33),
              data.count == 32,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token.range(of: #"^[0-9A-Fa-f]{32}$"#, options: .regularExpression) != nil ? token : nil
    }

    private static func isUsableConnectionTokenFile(
        _ tokenFileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        usableConnectionToken(tokenFileURL, fileManager: fileManager) != nil
    }

    private static func expandedHomePath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return homePath
        }
        return homePath + String(path.dropFirst())
    }

    private static func normalizedNamespace(_ bundleIdentifier: String?) -> String {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return "cmux"
        }
        return bundleIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
    }
}

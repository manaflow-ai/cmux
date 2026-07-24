import Darwin
import Foundation

/// Filesystem paths shared by the app-owned Computer Use runtime and agent wrappers.
struct ComputerUseRuntimePaths: Sendable {
    static let daemonSocketEnvironmentKey = "CMUX_CUA_SOCKET_PATH"
    static let stateDirectoryEnvironmentKey = "CMUX_CUA_STATE_DIR"
    static let runtimeScopeEnvironmentKey = "CMUX_CUA_RUNTIME_SCOPE"
    static let authenticationTokenEnvironmentKey = "CUA_DRIVER_SOCKET_AUTH_TOKEN"
    static let hostAuthenticationTokenEnvironmentKey = "CUA_DRIVER_SOCKET_HOST_AUTH_TOKEN"
    static let authenticationTokenFileEnvironmentKey = "CMUX_CUA_AUTH_TOKEN_FILE"

    let scope: String
    let authenticationToken: String
    /// Ephemeral capability reserved for host-only daemon operations.
    ///
    /// Unlike `authenticationToken`, this is never persisted or exposed to
    /// terminal agents. A new cmux process therefore has to replace or relaunch
    /// an orphaned helper before it can configure or stop that helper.
    let hostAuthenticationToken: String
    let computerUseDirectoryURL: URL
    let runtimeDirectoryURL: URL
    let daemonSocketURL: URL
    let authenticationTokenFileURL: URL
    let stateDirectoryURL: URL
    let permissionDatabaseDirectoryURL: URL
    let installedHelperDirectoryURL: URL
    let installedHelperAppURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        socketRootDirectoryURL: URL = FileManager.default.temporaryDirectory,
        userIdentifier: uid_t = getuid(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        authenticationToken: String? = nil,
        hostAuthenticationToken: String? = nil
    ) {
        let candidateScope: String
        if let rawTag = environment["CMUX_TAG"], !rawTag.isEmpty {
            // CMUX_TAG is user-controlled and sanitization is intentionally
            // lossy. Include a digest of the raw value so tags such as
            // "foo/bar" and "foo?bar" cannot share one helper daemon.
            candidateScope = Self.taggedScope(rawTag)
        } else {
            candidateScope = Self.sanitizedScope(
                environment[Self.runtimeScopeEnvironmentKey]
                    ?? environment["CMUX_BUNDLE_ID"]
                    ?? bundleIdentifier
            )
        }
        scope = Self.socketSafeScope(
            candidateScope,
            rootDirectoryURL: socketRootDirectoryURL,
            userIdentifier: userIdentifier
        )
        computerUseDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/cmux/computer-use", isDirectory: true)
        runtimeDirectoryURL = socketRootDirectoryURL
            .appendingPathComponent("cmux-cua-\(userIdentifier)", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
        daemonSocketURL = runtimeDirectoryURL.appendingPathComponent("cua.sock")
        authenticationTokenFileURL = runtimeDirectoryURL.appendingPathComponent("auth-token")
        self.authenticationToken = authenticationToken.flatMap(Self.nonEmptyToken)
            ?? Self.persistedAuthenticationToken(
                at: authenticationTokenFileURL,
                ownedBy: userIdentifier
            )
            ?? Self.makeAuthenticationToken()
        self.hostAuthenticationToken = hostAuthenticationToken.flatMap(Self.nonEmptyToken)
            ?? Self.makeAuthenticationToken()
        stateDirectoryURL = computerUseDirectoryURL
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        permissionDatabaseDirectoryURL = homeDirectoryURL
            .appendingPathComponent(
                "Library/Application Support/com.apple.TCC",
                isDirectory: true
            )
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
        // Preserve the complete sanitized identity here. `socketSafeScope`
        // performs the length bound and adds a stable hash when truncation is
        // required, so two long tags with the same prefix remain isolated.
        return candidate.isEmpty ? "default" : candidate
    }

    private static func taggedScope(_ rawTag: String) -> String {
        "\(sanitizedScope(rawTag))-\(stableScopeHash(rawTag))"
    }

    private static func socketSafeScope(
        _ candidate: String,
        rootDirectoryURL: URL,
        userIdentifier: uid_t
    ) -> String {
        let socketParent = rootDirectoryURL
            .appendingPathComponent("cmux-cua-\(userIdentifier)", isDirectory: true)
        let fixedByteCount = socketParent.path.utf8.count + "/".utf8.count + "/cua.sock".utf8.count
        let maximumScopeByteCount = max(1, 103 - fixedByteCount)
        guard candidate.utf8.count > maximumScopeByteCount else { return candidate }

        let hash = stableScopeHash(candidate)
        let suffix = "-\(hash)"
        let prefixByteCount = max(0, maximumScopeByteCount - suffix.utf8.count)
        if prefixByteCount == 0 {
            return String(hash.suffix(maximumScopeByteCount))
        }
        return String(candidate.prefix(prefixByteCount)) + suffix
    }

    private static func stableScopeHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let unpadded = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - unpadded.count)) + unpadded
    }

    private static func nonEmptyToken(_ rawValue: String) -> String? {
        rawValue.isEmpty ? nil : rawValue
    }

    /// Reuses the private scope credential across ordinary host restarts.
    ///
    /// Agent MCP proxies can outlive the cmux UI process. Rotating this token
    /// on every app launch leaves those otherwise healthy proxies permanently
    /// authenticated to the previous helper generation. The file is accepted
    /// only when the kernel confirms that it is a single-link, owner-only
    /// regular file; an explicit Computer Use disable still deletes it.
    private static func persistedAuthenticationToken(
        at fileURL: URL,
        ownedBy expectedOwner: uid_t
    ) -> String? {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == expectedOwner,
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600),
              metadata.st_size > 0,
              metadata.st_size <= 1_024
        else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    remainingByteCount
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }

        guard var token = String(bytes: bytes, encoding: .utf8) else { return nil }
        if token.last == "\n" {
            token.removeLast()
        }
        guard nonEmptyToken(token) != nil,
              token.utf8.count >= 32,
              token.utf8.count <= 256,
              token.utf8.allSatisfy({
                  ($0 >= 97 && $0 <= 122)
                      || ($0 >= 65 && $0 <= 90)
                      || ($0 >= 48 && $0 <= 57)
              })
        else {
            return nil
        }
        return token
    }

    private static func makeAuthenticationToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

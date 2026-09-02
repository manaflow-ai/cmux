public import Foundation
import CmuxSettings
import os

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

/// Identifies when a socket credential may be requested.
public nonisolated enum SocketCredentialResolutionDemand: Sendable {
    /// The first request on a newly connected socket. This demand only permits
    /// credentials supplied explicitly by the caller or environment.
    case initialConnection
    /// The server has returned an authentication challenge for a request.
    case authenticationRequired
}

/// Identifies the source that supplied a socket password.
public nonisolated enum SocketCredentialSource: Equatable, Sendable {
    case explicit
    case environment
    case file
    case keychain
}

/// Resolves socket credentials in precedence order, only consulting deferred
/// sources after the server requires authentication.
///
/// `@unchecked Sendable` is safe for the CLI handoff because every mutable
/// resolution field is guarded by ``resolutionLock``; source closures are
/// immutable and invoked while that lock is held.
public final class SocketCredentialResolver: @unchecked Sendable {
    /// Reads the first available password from the supplied keychain services.
    public typealias KeychainPasswordProvider = @Sendable (_ services: [String]) -> String?

    private enum ResolutionState {
        case unresolved
        case resolved(password: String?, source: SocketCredentialSource?)
    }

    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"

    private let explicitPassword: String?
    private let environment: [String: String]
    private let socketPath: String
    private let filePasswordProvider: @Sendable () -> String?
    private let keychainPasswordProvider: KeychainPasswordProvider
    /// Shared mode state for clients targeting this route.
    public let authenticationModeCoordinator: SocketAuthenticationModeCoordinator
    // The resolver is shared by synchronous CLI and detached readiness paths.
    // Security's lookup and SocketClient's send are synchronous; an actor hop
    // would require a blocking bridge and could reorder the auth retry. This
    // heap-stable lock is the synchronous single-flight boundary: it guards
    // state and one source invocation, never socket I/O, so concurrent paths
    // cannot create duplicate LocalAuthentication contexts.
    private let resolutionState = OSAllocatedUnfairLock<ResolutionState>(initialState: .unresolved)

    /// Creates a resolver with injectable file and keychain sources.
    ///
    /// The default sources read the same state-directory password file as the
    /// app and the legacy scoped keychain entries. Neither source is invoked by
    /// initialization or by ``password(for:)`` with ``SocketCredentialResolutionDemand/initialConnection``.
    public init(
        explicitPassword: String?,
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        filePasswordProvider: (@Sendable () -> String?)? = nil,
        keychainPasswordProvider: KeychainPasswordProvider? = nil,
        authenticationModeCoordinator: SocketAuthenticationModeCoordinator? = nil
    ) {
        self.explicitPassword = Self.normalized(explicitPassword)
        self.environment = environment
        self.socketPath = socketPath
        let defaultPasswordFileURL = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: fileManager)
        self.filePasswordProvider = filePasswordProvider ?? {
            Self.loadFromFile(url: defaultPasswordFileURL)
        }
        self.keychainPasswordProvider = keychainPasswordProvider ?? { services in
            Self.loadFromKeychain(services: services)
        }
        self.authenticationModeCoordinator = authenticationModeCoordinator ?? SocketAuthenticationModeCoordinator()
    }

    /// The flag or environment password, if present, without reading deferred sources.
    public var immediatePassword: String? {
        if let explicitPassword {
            return explicitPassword
        }
        return Self.normalized(environment["CMUX_SOCKET_PASSWORD"])
    }

    /// The source selected so far, or the immediate source without forcing a deferred read.
    public var source: SocketCredentialSource? {
        resolutionState.withLock { state in
            switch state {
            case .unresolved:
                if explicitPassword != nil { return .explicit }
                if Self.normalized(environment["CMUX_SOCKET_PASSWORD"]) != nil { return .environment }
                return nil
            case let .resolved(_, source):
                return source
            }
        }
    }

    /// The resolved password when a deferred demand has completed, without
    /// starting a new lookup.
    public var resolvedPassword: String? {
        resolutionState.withLock { state in
            switch state {
            case .unresolved:
                return immediatePassword
            case let .resolved(password, _):
                return password
            }
        }
    }

    /// Returns a password for the requested demand.
    ///
    /// Initial connection setup never reads the password file or keychain. A
    /// challenge resolves the complete precedence chain and caches its result,
    /// including a missing result, so each resolver performs at most one
    /// deferred lookup.
    public func password(
        for demand: SocketCredentialResolutionDemand,
        deadline: Date? = nil
    ) -> String? {
        switch demand {
        case .initialConnection:
            return immediatePassword
        case .authenticationRequired:
            return resolve(deadline: deadline)
        }
    }

    /// Resolves and memoizes the complete credential chain.
    public func resolve() -> String? {
        resolve(deadline: nil)
    }

    /// Resolves the credential chain without starting a source read after the deadline.
    public func resolve(deadline: Date?) -> String? {
        resolutionState.withLock { state in
            guard !Self.deadlineExpired(deadline) else { return nil }
            switch state {
            case let .resolved(password, _):
                return password
            case .unresolved:
                break
            }

            if let explicitPassword {
                state = .resolved(password: explicitPassword, source: .explicit)
                return explicitPassword
            }
            if let environmentPassword = Self.normalized(environment["CMUX_SOCKET_PASSWORD"]) {
                state = .resolved(password: environmentPassword, source: .environment)
                return environmentPassword
            }
            if let filePassword = Self.normalized(filePasswordProvider()) {
                state = .resolved(password: filePassword, source: .file)
                return filePassword
            }
            guard !Self.deadlineExpired(deadline) else { return nil }
            let services = Self.keychainServices(socketPath: socketPath, environment: environment)
            if let keychainPassword = Self.normalized(keychainPasswordProvider(services)) {
                state = .resolved(password: keychainPassword, source: .keychain)
                return keychainPassword
            }
            state = .resolved(password: nil, source: nil)
            return nil
        }
    }

    /// Returns scoped and unscoped legacy keychain service names in lookup order.
    public static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deadlineExpired(_ deadline: Date?) -> Bool {
        guard let deadline else { return false }
        return deadline.timeIntervalSinceNow <= 0
    }

    private static func loadFromFile(url: URL?) -> String? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String]
    ) -> String? {
        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            if let scoped = SocketPathMarkerFiles.sanitizeSocketSlug(String(candidate[start..<end])) {
                return scoped
            }
        }
        return normalized(environment["CMUX_TAG"]).flatMap(SocketPathMarkerFiles.sanitizeSocketSlug)
    }

    /// Reads the legacy keychain entries for a single socket service scope.
    static func loadFromKeychain(services: [String]) -> String? {
#if canImport(Security) && canImport(LocalAuthentication)
        let authContext = LAContext()
        authContext.interactionNotAllowed = true
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
#endif
        return nil
    }
}

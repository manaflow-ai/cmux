import Foundation
import CmuxSettings

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

/// Identifies when a socket credential may be requested.
enum SocketCredentialResolutionDemand {
    /// The first request on a newly connected socket. This demand only permits
    /// credentials supplied explicitly by the caller or environment.
    case initialConnection
    /// The server has returned an authentication challenge for a request.
    case authenticationRequired
}

/// Identifies the source that supplied a socket password.
enum SocketCredentialSource: Equatable {
    case explicit
    case environment
    case file
    case keychain
}

/// Resolves socket credentials in precedence order, only consulting deferred
/// sources after the server requires authentication.
final class SocketCredentialResolver {
    typealias KeychainPasswordProvider = (_ services: [String]) -> String?

    private enum ResolutionState {
        case unresolved
        case resolved(password: String?, source: SocketCredentialSource?)
    }

    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"

    private let explicitPassword: String?
    private let environment: [String: String]
    private let socketPath: String
    private let filePasswordProvider: () -> String?
    private let keychainPasswordProvider: KeychainPasswordProvider
    private var resolutionState = ResolutionState.unresolved

    /// Creates a resolver with injectable file and keychain sources.
    ///
    /// The default sources read the same state-directory password file as the
    /// app and the legacy scoped keychain entries. Neither source is invoked by
    /// initialization or by ``password(for:)`` with ``SocketCredentialResolutionDemand/initialConnection``.
    init(
        explicitPassword: String?,
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        filePasswordProvider: (() -> String?)? = nil,
        keychainPasswordProvider: KeychainPasswordProvider? = nil
    ) {
        self.explicitPassword = Self.normalized(explicitPassword)
        self.environment = environment
        self.socketPath = socketPath
        self.filePasswordProvider = filePasswordProvider ?? {
            Self.loadFromFile(fileManager: fileManager)
        }
        self.keychainPasswordProvider = keychainPasswordProvider ?? { services in
            Self.loadFromKeychain(services: services)
        }
    }

    /// The flag or environment password, if present, without reading deferred sources.
    var immediatePassword: String? {
        if let explicitPassword {
            return explicitPassword
        }
        return Self.normalized(environment["CMUX_SOCKET_PASSWORD"])
    }

    /// The source selected so far, or the immediate source without forcing a deferred read.
    var source: SocketCredentialSource? {
        switch resolutionState {
        case .unresolved:
            if explicitPassword != nil { return .explicit }
            if Self.normalized(environment["CMUX_SOCKET_PASSWORD"]) != nil { return .environment }
            return nil
        case let .resolved(_, source):
            return source
        }
    }

    /// The resolved password when a deferred demand has completed, without
    /// starting a new lookup.
    var resolvedPassword: String? {
        switch resolutionState {
        case .unresolved:
            return immediatePassword
        case let .resolved(password, _):
            return password
        }
    }

    /// Returns a password for the requested demand.
    ///
    /// Initial connection setup never reads the password file or keychain. A
    /// challenge resolves the complete precedence chain and caches its result,
    /// including a missing result, so each resolver performs at most one
    /// deferred lookup.
    func password(for demand: SocketCredentialResolutionDemand) -> String? {
        switch demand {
        case .initialConnection:
            return immediatePassword
        case .authenticationRequired:
            return resolve()
        }
    }

    /// Resolves and memoizes the complete credential chain.
    func resolve() -> String? {
        switch resolutionState {
        case let .resolved(password, _):
            return password
        case .unresolved:
            break
        }

        if let explicitPassword {
            resolutionState = .resolved(password: explicitPassword, source: .explicit)
            return explicitPassword
        }
        if let environmentPassword = Self.normalized(environment["CMUX_SOCKET_PASSWORD"]) {
            resolutionState = .resolved(password: environmentPassword, source: .environment)
            return environmentPassword
        }
        if let filePassword = Self.normalized(filePasswordProvider()) {
            resolutionState = .resolved(password: filePassword, source: .file)
            return filePassword
        }
        let services = Self.keychainServices(socketPath: socketPath, environment: environment)
        if let keychainPassword = Self.normalized(keychainPasswordProvider(services)) {
            resolutionState = .resolved(password: keychainPassword, source: .keychain)
            return keychainPassword
        }
        resolutionState = .resolved(password: nil, source: nil)
        return nil
    }

    /// Returns scoped and unscoped legacy keychain service names in lookup order.
    static func keychainServices(
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

    private static func loadFromFile(fileManager: FileManager) -> String? {
        guard let passwordURL = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: fileManager),
              let data = try? Data(contentsOf: passwordURL),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String]
    ) -> String? {
        if let tag = normalized(environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let scoped = sanitizeScope(String(candidate[start..<end]))
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = raw.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        return normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func loadFromKeychain(services: [String]) -> String? {
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

/// Owns credential resolvers for one CLI process so each socket route shares
/// its single deferred lookup and memoized keychain result.
final class SocketCredentialResolutionSession {
    private let environment: [String: String]
    private var resolvers: [String: SocketCredentialResolver] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment.filter {
            $0.key == "CMUX_SOCKET_PASSWORD" || $0.key == "CMUX_TAG"
        }
    }

    func resolver(explicitPassword: String?, socketPath: String) -> SocketCredentialResolver {
        // A CLI invocation has one credential policy per socket route. Keep
        // secrets out of the cache key; the resolver itself owns the value.
        let policyKey = explicitPassword == nil ? "implicit" : "explicit"
        let key = "\(socketPath)\u{1f}\(policyKey)"
        if let existing = resolvers[key] {
            return existing
        }
        let resolver = SocketCredentialResolver(
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            environment: environment
        )
        resolvers[key] = resolver
        return resolver
    }
}

/// Compatibility facade for call sites that explicitly need an eager password value.
enum SocketPasswordResolver {
    /// Resolves the complete credential chain immediately.
    static func resolve(
        explicit: String?,
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        filePasswordProvider: (() -> String?)? = nil,
        keychainPasswordProvider: SocketCredentialResolver.KeychainPasswordProvider? = nil
    ) -> String? {
        SocketCredentialResolver(
            explicitPassword: explicit,
            socketPath: socketPath,
            environment: environment,
            fileManager: fileManager,
            filePasswordProvider: filePasswordProvider,
            keychainPasswordProvider: keychainPasswordProvider
        ).resolve()
    }

    /// Returns the service names used by scoped and unscoped legacy entries.
    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        SocketCredentialResolver.keychainServices(socketPath: socketPath, environment: environment)
    }
}

public import Foundation

/// Owns credential resolvers for one CLI process.
///
/// Implicit credentials are shared by socket route so reconnect, readiness,
/// resize, and feed paths reuse one memoized deferred lookup. Explicit
/// passwords always receive a fresh resolver because they are per-call input.
/// The short lock protects resolver publication when detached CLI work asks for
/// the same route concurrently; credential I/O remains owned by the resolver.
private final class KeychainLookupMemoizer: @unchecked Sendable {
    private enum State {
        case unresolved
        case resolved(String?)
    }

    private let lock = NSLock()
    private var state = State.unresolved

    func password(
        services: [String],
        provider: SocketCredentialResolver.KeychainPasswordProvider
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if case let .resolved(password) = state {
            return password
        }
        let password = provider(services)
        state = .resolved(password)
        return password
    }
}

/// Owns credential resolvers for one CLI process.
public final class SocketCredentialResolutionSession: @unchecked Sendable {
    private let environment: [String: String]
    private let filePasswordProvider: (() -> String?)?
    private let keychainPasswordProvider: SocketCredentialResolver.KeychainPasswordProvider
    private let resolverLock = NSLock()
    private var resolvers: [String: SocketCredentialResolver] = [:]

    /// Creates a process-scoped resolution session.
    /// - Parameters:
    ///   - environment: The environment snapshot used by every resolver.
    ///   - filePasswordProvider: An optional injected file source for tests.
    ///   - keychainPasswordProvider: An optional injected keychain source for tests.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filePasswordProvider: (() -> String?)? = nil,
        keychainPasswordProvider: SocketCredentialResolver.KeychainPasswordProvider? = nil
    ) {
        self.environment = environment.filter {
            $0.key == "CMUX_SOCKET_PASSWORD" || $0.key == "CMUX_TAG"
        }
        self.filePasswordProvider = filePasswordProvider
        let memoizer = KeychainLookupMemoizer()
        let provider = keychainPasswordProvider ?? { services in
            SocketCredentialResolver.loadFromKeychain(services: services)
        }
        self.keychainPasswordProvider = { services in
            memoizer.password(services: services, provider: provider)
        }
    }

    /// Returns the resolver for a socket route without consulting deferred sources.
    /// - Parameters:
    ///   - explicitPassword: A per-call password supplied by `--password`.
    ///   - socketPath: The target control-socket path.
    /// - Returns: A fresh explicit resolver or the shared implicit resolver for the route.
    public func resolver(
        explicitPassword: String?,
        socketPath: String
    ) -> SocketCredentialResolver {
        if explicitPassword != nil {
            return SocketCredentialResolver(
                explicitPassword: explicitPassword,
                socketPath: socketPath,
                environment: environment,
                filePasswordProvider: filePasswordProvider,
                keychainPasswordProvider: keychainPasswordProvider
            )
        }

        resolverLock.lock()
        defer { resolverLock.unlock() }
        if let existing = resolvers[socketPath] {
            return existing
        }
        let resolver = SocketCredentialResolver(
            explicitPassword: nil,
            socketPath: socketPath,
            environment: environment,
            filePasswordProvider: filePasswordProvider,
            keychainPasswordProvider: self.keychainPasswordProvider
        )
        resolvers[socketPath] = resolver
        return resolver
    }
}

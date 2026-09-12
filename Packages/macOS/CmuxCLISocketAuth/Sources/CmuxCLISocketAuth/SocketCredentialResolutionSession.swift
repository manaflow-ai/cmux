public import Foundation
import os

/// Memoizes one keychain lookup per service scope for a CLI process.
///
/// The lock serializes concurrent lookups for the same scope so a single CLI
/// invocation creates at most one `LocalAuthentication` context per scope.
private final class KeychainLookupMemoizer: @unchecked Sendable {
    private enum State {
        case resolved(String?)
    }

    private let states = OSAllocatedUnfairLock<[String: State]>(initialState: [:])
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Returns the cached result for a service scope, loading it once when needed.
    /// Results that complete after a supplied deadline are returned to the
    /// current resolver but are not retained for later routes.
    ///
    /// The provider wraps synchronous `SecItemCopyMatching`/`LAContext` calls.
    /// Holding this short process-local lock across that one call is intentional:
    /// releasing it would let concurrent synchronous CLI paths duplicate the
    /// keychain read. An actor would require a blocking bridge at the same API
    /// boundary and would not improve the wire-level ordering guarantee.
    func password(
        services: [String],
        deadline: Date?,
        provider: SocketCredentialResolver.KeychainPasswordProvider
    ) -> String? {
        states.withLock { state in
            let key = services.joined(separator: "\u{1f}")
            if case let .resolved(password) = state[key] {
                return password
            }
            let password = provider(services)
            // A late result belongs to the current resolver, not the shared
            // scope cache; a later operation must be able to retry a miss.
            if let deadline, now() >= deadline {
                return password
            }
            state[key] = .resolved(password)
            return password
        }
    }
}

/// Owns credential resolvers for one CLI process.
public final class SocketCredentialResolutionSession: @unchecked Sendable {
    private let environment: [String: String]
    private let filePasswordProvider: (@Sendable () -> String?)?
    private let keychainPasswordProvider: SocketCredentialResolver.DeadlineKeychainPasswordProvider
    private let now: @Sendable () -> Date
    // Resolver publication is called from synchronous CLI setup, while the
    // resulting resolver may be handed to detached readiness work. This
    // heap-stable lock protects only the tiny dictionary publication section;
    // source I/O stays inside each resolver's single-flight boundary below.
    private struct State {
        var resolvers: [String: SocketCredentialResolver] = [:]
        var authenticationModeCoordinators: [String: SocketAuthenticationModeCoordinator] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Creates a process-scoped resolution session.
    /// - Parameters:
    ///   - environment: The environment snapshot used by every resolver.
    ///   - filePasswordProvider: An optional injected file source for tests.
    ///   - keychainPasswordProvider: An optional injected keychain source for tests.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filePasswordProvider: (@Sendable () -> String?)? = nil,
        keychainPasswordProvider: SocketCredentialResolver.KeychainPasswordProvider? = nil
    ) {
        self.init(
            environment: environment,
            filePasswordProvider: filePasswordProvider,
            keychainPasswordProvider: keychainPasswordProvider,
            now: { Date.now }
        )
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filePasswordProvider: (@Sendable () -> String?)? = nil,
        keychainPasswordProvider: SocketCredentialResolver.KeychainPasswordProvider? = nil,
        now: @escaping @Sendable () -> Date
    ) {
        self.environment = environment.filter {
            $0.key == "CMUX_SOCKET_PASSWORD" || $0.key == "CMUX_TAG"
        }
        self.filePasswordProvider = filePasswordProvider
        self.now = now
        let memoizer = KeychainLookupMemoizer(now: now)
        let provider = keychainPasswordProvider ?? { services in
            SocketCredentialResolver.loadFromKeychain(services: services)
        }
        self.keychainPasswordProvider = { services, deadline in
            memoizer.password(services: services, deadline: deadline, provider: provider)
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
        let modeCoordinator = authenticationModeCoordinator(for: socketPath)
        if explicitPassword != nil {
            return SocketCredentialResolver(
                explicitPassword: explicitPassword,
                socketPath: socketPath,
                environment: environment,
                filePasswordProvider: filePasswordProvider,
                deadlineKeychainPasswordProvider: self.keychainPasswordProvider,
                authenticationModeCoordinator: modeCoordinator,
                now: now
            )
        }

        return state.withLock { state in
            if let existing = state.resolvers[socketPath] {
                return existing
            }
            let resolver = SocketCredentialResolver(
                explicitPassword: nil,
                socketPath: socketPath,
                environment: environment,
                filePasswordProvider: filePasswordProvider,
                deadlineKeychainPasswordProvider: self.keychainPasswordProvider,
                authenticationModeCoordinator: modeCoordinator,
                now: now
            )
            state.resolvers[socketPath] = resolver
            return resolver
        }
    }

    private func authenticationModeCoordinator(for socketPath: String) -> SocketAuthenticationModeCoordinator {
        state.withLock { state in
            if let existing = state.authenticationModeCoordinators[socketPath] {
                return existing
            }
            let coordinator = SocketAuthenticationModeCoordinator()
            state.authenticationModeCoordinators[socketPath] = coordinator
            return coordinator
        }
    }
}

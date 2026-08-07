import Foundation

/// Resolves internally minted agent IDs from a durable session store during one process scan.
///
/// Fresh processes are registered before lookup so a persisted row is used only when exactly one
/// live process can own it. Resolution is cached for the scan and fails closed on every ambiguity.
public struct CmuxVaultPersistedSessionResolver: Sendable {
    private struct LookupKey: Hashable, Sendable {
        let store: CmuxVaultAgentPersistedSessionStore
        let storePath: String
        let canonicalCwd: String
    }

    private enum CachedResolution: Sendable {
        case found(String)
        case missing
    }

    private let allowsStoreReads: Bool
    private var freshProcessCountByKey: [LookupKey: Int] = [:]
    private var cachedResolutionByKey: [LookupKey: CachedResolution] = [:]

    /// Creates a resolver for one process scan.
    ///
    /// - Parameter allowsStoreReads: Whether this scan may access persisted session stores. Pass
    ///   `false` on synchronous UI or termination paths so fresh sessions fail closed without I/O.
    public init(allowsStoreReads: Bool = true) {
        self.allowsStoreReads = allowsStoreReads
    }

    /// Registers a fresh process as a possible owner of a persisted session row.
    ///
    /// - Parameters:
    ///   - store: The cmux-owned persisted store capability.
    ///   - environment: The observed process environment used to locate the store.
    ///   - cwd: The working directory captured from the live process.
    public mutating func registerFreshProcess(
        store: CmuxVaultAgentPersistedSessionStore,
        environment: [String: String],
        cwd: String
    ) {
        guard allowsStoreReads,
              let key = lookupKey(store: store, environment: environment, cwd: cwd) else {
            return
        }
        freshProcessCountByKey[key, default: 0] += 1
    }

    /// Returns the sole persisted session ID owned by one registered fresh process.
    ///
    /// - Parameters:
    ///   - store: The cmux-owned persisted store capability.
    ///   - environment: The observed process environment used to locate the store.
    ///   - cwd: The working directory captured from the live process.
    /// - Returns: The unique active session ID, or `nil` when ownership or store contents are
    ///   missing, ambiguous, unavailable, or disabled for this scan.
    public mutating func uniqueSessionID(
        store: CmuxVaultAgentPersistedSessionStore,
        environment: [String: String],
        cwd: String
    ) -> String? {
        guard allowsStoreReads,
              let key = lookupKey(store: store, environment: environment, cwd: cwd),
              freshProcessCountByKey[key] == 1 else {
            return nil
        }
        if let cached = cachedResolutionByKey[key] {
            switch cached {
            case .found(let sessionID):
                return sessionID
            case .missing:
                return nil
            }
        }

        let resolved: String?
        switch store {
        case .hermesStateDB:
            resolved = HermesAgentStateDBResolver().uniqueActiveSessionID(
                cwd: cwd,
                stateDBPath: key.storePath
            )
        }
        cachedResolutionByKey[key] = resolved.map(CachedResolution.found) ?? .missing
        return resolved
    }

    private func lookupKey(
        store: CmuxVaultAgentPersistedSessionStore,
        environment: [String: String],
        cwd: String
    ) -> LookupKey? {
        let storePath: String
        let canonicalCwd: String?
        switch store {
        case .hermesStateDB:
            storePath = HermesAgentSessionResolver.stateDBPath(env: environment)
            canonicalCwd = HermesAgentStateDBResolver().canonicalCwd(cwd)
        }
        guard let canonicalCwd else { return nil }
        return LookupKey(
            store: store,
            storePath: (storePath as NSString).standardizingPath,
            canonicalCwd: canonicalCwd
        )
    }
}

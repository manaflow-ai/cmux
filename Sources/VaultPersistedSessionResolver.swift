import CMUXAgentLaunch
import Foundation

/// Per-scan resolver for agent IDs that are minted internally and exposed only through a durable
/// session store. The scanner registers fresh processes first, then resolves only unambiguous keys.
struct VaultPersistedSessionResolver {
    private struct LookupKey: Hashable {
        let store: CmuxVaultAgentPersistedSessionStore
        let storePath: String
        let canonicalCwd: String
    }

    private enum CachedResolution {
        case found(String)
        case missing
    }

    private var freshProcessCountByKey: [LookupKey: Int] = [:]
    private var cachedResolutionByKey: [LookupKey: CachedResolution] = [:]

    mutating func registerFreshProcesses(
        processes: [CmuxTopProcessInfo],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        registryProvider: (String?) -> CmuxVaultAgentRegistry
    ) {
        for process in processes {
            guard process.cmuxWorkspaceID != nil,
                  process.cmuxSurfaceID != nil,
                  let processArguments = processArgumentsProvider(process.pid) else {
                continue
            }
            let observed = VaultObservedAgentProcess(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments.arguments,
                environment: processArguments.environment
            )
            let cwd = Self.normalized(
                observed.environment["CMUX_AGENT_LAUNCH_CWD"] ?? observed.environment["PWD"]
            )
            guard let cwd,
                  let registration = registryProvider(cwd).matchingRegistration(for: observed),
                  case .persistedStore(let store) = registration.sessionIdSource,
                  registration.persistedSessionStoreCapability == store,
                  store.explicitSessionID(arguments: observed.arguments) == nil,
                  let key = lookupKey(store: store, environment: observed.environment, cwd: cwd) else {
                continue
            }
            freshProcessCountByKey[key, default: 0] += 1
        }
    }

    mutating func uniqueSessionID(
        store: CmuxVaultAgentPersistedSessionStore,
        environment: [String: String],
        cwd: String
    ) -> String? {
        guard let key = lookupKey(store: store, environment: environment, cwd: cwd),
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

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

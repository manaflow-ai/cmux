import CmuxFoundation
import Foundation

/// Process-backed index loading shares census ownership and preserves cancellation.
extension RestorableAgentSessionIndex {
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        let snapshot = await CmuxTopProcessSnapshot.capture(includeProcessDetails: true, includeResources: false)
        return loadIncludingProcessDetectedSnapshotsSynchronously(
            processSnapshot: snapshot, homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }
    /// Manual hibernation, memory-pressure reclaim and the teardown's final
    /// revalidation read this index, so it scopes hook-backed agents exactly
    /// as ``SharedLiveAgentIndexLoader`` does.
    static func loadIncludingProcessDetectedSnapshotsSynchronously(
        processSnapshot: CmuxTopProcessSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        processArgumentsProvider: @escaping (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        }
    ) -> RestorableAgentSessionIndex {
        guard processSnapshot.captureIsAvailable, processSnapshot.enumerationIsComplete, !Task.isCancelled else { return .unavailable }
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: processSnapshot.sampledAt.timeIntervalSince1970,
            processArgumentsProvider: processArgumentsProvider
        )
        let hibernationProcessScopes = detectedSnapshots.mapValues { detected in
            processSnapshot.agentHibernationProcessScope(
                panelProcessIDs: detected.processIDs,
                agentProcessIDs: detected.agentProcessIDs
            )
        }
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            hibernationProcessScopes: hibernationProcessScopes,
            hookProcessScopeProvider: SharedLiveAgentIndexLoader.hookProcessScopeProvider(
                processSnapshot: processSnapshot,
                processArgumentsProvider: processArgumentsProvider
            ),
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider
        )
    }
}

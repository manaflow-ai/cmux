import CMUXAgentLaunch
import Darwin
import Foundation
import os

nonisolated private let agentConversationExportLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "AgentConversationExport"
)

nonisolated private let agentConversationTransferRetention =
    SessionTranscriptRetention.transferOpeningUserAndLatest(
        turnLimit: 1_000,
        textByteLimit: 256 * 1_024
    )

/// Exact source identity used to revalidate a cross-harness transfer.
nonisolated struct AgentConversationTransferIdentity: Equatable, Sendable {
    let kind: RestorableAgentKind
    let sessionId: String
    let storagePath: String
}

/// Process generation recorded synchronously by the panel's hook/runtime path.
nonisolated struct AgentConversationRuntimeProcessIdentity: Equatable, Sendable {
    let key: String
    let pid: pid_t?
    let processIdentity: AgentPIDProcessIdentity?
}

/// Cheap in-memory evidence that the panel still owns the same agent run.
nonisolated struct AgentConversationPanelStateToken: Equatable, Sendable {
    let restoredTransferIdentity: AgentConversationTransferIdentity?
    let bindingSource: String?
    let bindingKind: String?
    let bindingSessionId: String?
    let runtimeProcessIdentities: [AgentConversationRuntimeProcessIdentity]
}

/// Storage-independent identity for one source conversation.
nonisolated struct AgentConversationSource: Sendable {
    let kind: RestorableAgentKind
    let sessionId: String
    let workingDirectory: String?
    let transcriptPath: String?
    let registration: CmuxVaultAgentRegistration?
    let launchEnvironment: [String: String]
    let sessionIDProvenance: AgentSessionIDProvenance?

    init(snapshot: SessionRestorableAgentSnapshot) {
        kind = snapshot.kind
        sessionId = snapshot.sessionId
        workingDirectory = snapshot.workingDirectory
        transcriptPath = snapshot.transcriptPath
        registration = snapshot.registration
        launchEnvironment = snapshot.launchCommand?.environment ?? [:]
        sessionIDProvenance = snapshot.sessionIDProvenance
    }

    var sessionAgent: SessionAgent {
        switch kind {
        case .claude:
            .claude
        case .codex:
            .codex
        case .grok:
            .grok
        case .opencode:
            .opencode
        case .rovodev:
            .rovodev
        case .hermesAgent:
            .hermesAgent
        default:
            .registered(RegisteredSessionAgent(
                id: kind.rawValue,
                name: registration?.name,
                iconAssetName: registration?.iconAssetName
            ))
        }
    }

    var transcriptURL: URL? {
        guard let path = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var hasDeterministicTranscriptSource: Bool {
        switch kind {
        case .opencode:
            openCodeDatabasePath != nil
                && sessionIDProvenance == .authoritative
        case .hermesAgent:
            hermesStateDatabaseURL != nil
                && sessionIDProvenance == .authoritative
        default:
            transcriptURL != nil
        }
    }

    /// Stable identity of the exact conversation storage selected for export.
    /// Execution refreshes this identity before and after reading so a cached
    /// session cannot redirect a cross-harness transfer.
    var transferIdentity: AgentConversationTransferIdentity? {
        guard hasDeterministicTranscriptSource else { return nil }
        let storageIdentity: String?
        switch kind {
        case .opencode:
            storageIdentity = openCodeDatabasePath
        case .hermesAgent:
            storageIdentity = hermesStateDatabaseURL?.standardizedFileURL.path
        default:
            storageIdentity = transcriptURL?.standardizedFileURL.path
        }
        guard let storageIdentity else { return nil }
        return AgentConversationTransferIdentity(
            kind: kind,
            sessionId: sessionId,
            storagePath: storageIdentity
        )
    }

    /// Provider databases and captured transcript paths are authoritative. A
    /// provider without captured storage identity must still fail closed rather
    /// than falling back to indexed discovery or the current process's home.
    var requiresAuthoritativeTranscriptRead: Bool {
        switch kind {
        case .opencode, .hermesAgent:
            true
        default:
            transcriptURL != nil
        }
    }

    var hermesStateDatabaseURL: URL? {
        guard kind == .hermesAgent,
              hasCapturedEnvironmentValue(for: ["HERMES_HOME", "HOME"]) else {
            return nil
        }
        return URL(
            fileURLWithPath: HermesAgentSessionResolver.stateDBPath(env: launchEnvironment),
            isDirectory: false
        )
    }

    var openCodeDatabasePath: String? {
        guard kind == .opencode else { return nil }
        guard hasCapturedEnvironmentValue(for: [
            OpenCodeSessionResolver.capturedDatabasePathEnvironmentKey,
            "OPENCODE_DB",
        ]) || usesOpenCodeSharedChannelDatabase else {
            return nil
        }
        return OpenCodeSessionResolver(defaultHomeDirectory: NSHomeDirectory())
            .capturedDatabasePath(env: launchEnvironment)
    }

    var usesGrokTranscriptLayout: Bool {
        if kind == .grok {
            return true
        }
        guard let registration else { return false }
        if case .grokSessionDirectory = registration.sessionIdSource {
            return true
        }
        return false
    }

    private func hasCapturedEnvironmentValue(for keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = launchEnvironment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var usesOpenCodeSharedChannelDatabase: Bool {
        let value = launchEnvironment["OPENCODE_DISABLE_CHANNEL_DB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true"
    }
}

/// One pluggable source adapter. Returning nil lets the registry try a fallback
/// only when cmux did not capture a deterministic transcript source.
nonisolated protocol AgentConversationSourceAdapter: Sendable {
    func supports(_ source: AgentConversationSource) -> Bool
    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]?
}

nonisolated enum AgentConversationExportError: Error, Equatable, Sendable {
    case sourceUnavailable(String)
    case emptyConversation
}

/// Ordered adapter registry: databases, direct files, then indexed discovery.
nonisolated struct AgentConversationReaderRegistry: Sendable {
    static let live = AgentConversationReaderRegistry(adapters: [
        OpenCodeAgentConversationSourceAdapter(),
        HermesAgentConversationSourceAdapter(),
        DirectTranscriptAgentConversationSourceAdapter(),
        IndexedAgentConversationSourceAdapter(),
    ])

    let adapters: [any AgentConversationSourceAdapter]

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn] {
        var lastError: (any Error)?
        for adapter in adapters where adapter.supports(source) {
            do {
                let turns = try await adapter.read(source)
                if let turns, !turns.isEmpty {
                    return turns
                }
                if source.requiresAuthoritativeTranscriptRead {
                    guard case .some = turns else {
                        throw AgentConversationExportError.sourceUnavailable(source.kind.rawValue)
                    }
                    throw AgentConversationExportError.emptyConversation
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if source.requiresAuthoritativeTranscriptRead {
                    agentConversationExportLogger.error(
                        "Authoritative conversation reader failed kind=\(source.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
                    throw error
                }
                lastError = error
            }
        }
        if let lastError {
            agentConversationExportLogger.error(
                "Conversation reader failed kind=\(source.kind.rawValue, privacy: .public): \(lastError.localizedDescription, privacy: .private)"
            )
        }
        throw AgentConversationExportError.sourceUnavailable(source.kind.rawValue)
    }
}

nonisolated struct OpenCodeAgentConversationSourceAdapter: AgentConversationSourceAdapter {
    let databasePath: String?

    init(databasePath: String? = nil) {
        self.databasePath = databasePath
    }

    func supports(_ source: AgentConversationSource) -> Bool {
        source.kind == .opencode
    }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        guard let resolvedDatabasePath = databasePath ?? source.openCodeDatabasePath else {
            throw AgentConversationExportError.sourceUnavailable(source.kind.rawValue)
        }
        return try await SessionTranscriptLoader.load(source: .init(
            agent: .opencode,
            sessionId: source.sessionId,
            fileURL: nil,
            openCodeDatabasePath: resolvedDatabasePath,
            retention: agentConversationTransferRetention
        ))
    }
}

nonisolated struct HermesAgentConversationSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool {
        source.kind == .hermesAgent
    }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        guard let stateDatabaseURL = source.hermesStateDatabaseURL else {
            throw AgentConversationExportError.sourceUnavailable(source.kind.rawValue)
        }
        return try await SessionTranscriptLoader.load(source: .init(
            agent: .hermesAgent,
            sessionId: source.sessionId,
            fileURL: nil,
            hermesStateDatabaseURL: stateDatabaseURL,
            retention: agentConversationTransferRetention
        ))
    }
}

nonisolated struct DirectTranscriptAgentConversationSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool {
        guard let url = source.transcriptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        guard let url = source.transcriptURL else { return nil }
        return try await SessionTranscriptLoader.load(source: .init(
            agent: source.sessionAgent,
            sessionId: source.sessionId,
            fileURL: url,
            usesGrokTranscriptLayout: source.usesGrokTranscriptLayout,
            retention: agentConversationTransferRetention
        ))
    }
}

nonisolated struct IndexedAgentConversationSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool {
        !source.hasDeterministicTranscriptSource
            && source.kind != .opencode
            && source.kind != .hermesAgent
    }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        guard let entry = await SessionIndexStore.resolveConversationEntry(source: source) else {
            return nil
        }
        return try await SessionTranscriptLoader.load(
            entry: entry,
            retention: agentConversationTransferRetention
        )
    }
}

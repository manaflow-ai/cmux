import Foundation
import os

nonisolated private let agentConversationExportLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "AgentConversationExport"
)

nonisolated private let agentConversationTransferRetention =
    SessionTranscriptRetention.openingUserAndLatest(1_000)

/// Storage-independent identity for one source conversation.
nonisolated struct AgentConversationSource: Sendable {
    let kind: RestorableAgentKind
    let sessionId: String
    let workingDirectory: String?
    let transcriptPath: String?
    let registration: CmuxVaultAgentRegistration?

    init(snapshot: SessionRestorableAgentSnapshot) {
        kind = snapshot.kind
        sessionId = snapshot.sessionId
        workingDirectory = snapshot.workingDirectory
        transcriptPath = snapshot.transcriptPath
        registration = snapshot.registration
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
}

/// One pluggable source adapter. Returning nil lets the registry try a fallback.
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
                if let turns = try await adapter.read(source), !turns.isEmpty {
                    return turns
                }
            } catch {
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
        try await SessionTranscriptLoader.load(source: .init(
            agent: .opencode,
            sessionId: source.sessionId,
            fileURL: nil,
            openCodeDatabasePath: databasePath,
            retention: agentConversationTransferRetention
        ))
    }
}

nonisolated struct HermesAgentConversationSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool {
        source.kind == .hermesAgent
    }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        try await SessionTranscriptLoader.load(source: .init(
            agent: .hermesAgent,
            sessionId: source.sessionId,
            fileURL: nil,
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
        source.kind != .opencode && source.kind != .hermesAgent
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

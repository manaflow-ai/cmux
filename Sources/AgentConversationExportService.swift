import Foundation
import os

nonisolated private let agentConversationExportLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "AgentConversationExport"
)

nonisolated private let agentConversationTransferRetention =
    SessionTranscriptLoader.Retention.openingUserAndLatest(1_000)

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
            return .claude
        case .codex:
            return .codex
        case .grok:
            return .grok
        case .opencode:
            return .opencode
        case .rovodev:
            return .rovodev
        case .hermesAgent:
            return .hermesAgent
        default:
            let registered = RegisteredSessionAgent(
                id: kind.rawValue,
                name: registration?.name,
                iconAssetName: registration?.iconAssetName
            )
            return .registered(registered)
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

/// One pluggable storage adapter. Returning nil lets the registry try the next adapter.
nonisolated protocol AgentConversationSourceAdapter: Sendable {
    func supports(_ source: AgentConversationSource) -> Bool
    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]?
}

nonisolated enum AgentConversationExportError: Error, Equatable {
    case sourceUnavailable(String)
    case emptyConversation
}

/// Ordered adapter registry. Specific database readers precede file and indexed fallbacks.
nonisolated struct AgentConversationReaderRegistry: Sendable {
    static let live = AgentConversationReaderRegistry(adapters: [
        OpenCodeAgentConversationSourceAdapter(),
        HermesAgentConversationSourceAdapter(),
        DirectTranscriptAgentConversationSourceAdapter(),
        IndexedAgentConversationSourceAdapter(),
    ])

    let adapters: [any AgentConversationSourceAdapter]

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn] {
        var lastError: Error?
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
                "Conversation reader failed kind=\(source.kind.rawValue, privacy: .public): \(lastError.localizedDescription, privacy: .public)"
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

nonisolated struct AgentConversationExportPolicy: Equatable, Sendable {
    var maximumCharacters: Int
    var initialUserCharacterLimit: Int
    var includesSystemTurns: Bool
    var includesToolTurns: Bool

    init(
        maximumCharacters: Int = 24_000,
        initialUserCharacterLimit: Int = 4_000,
        includesSystemTurns: Bool = false,
        includesToolTurns: Bool = false
    ) {
        self.maximumCharacters = max(1_024, maximumCharacters)
        self.initialUserCharacterLimit = max(0, initialUserCharacterLimit)
        self.includesSystemTurns = includesSystemTurns
        self.includesToolTurns = includesToolTurns
    }

    func includes(_ role: SessionTranscriptRole) -> Bool {
        switch role {
        case .user, .assistant:
            return true
        case .system:
            return includesSystemTurns
        case .tool:
            return includesToolTurns
        case .event:
            return false
        }
    }
}

nonisolated struct AgentConversationCompaction: Equatable, Sendable {
    let turns: [SessionTranscriptTurn]
    let omittedTurnCount: Int
    let shortenedTurnCount: Int
}

nonisolated protocol AgentConversationCompacting: Sendable {
    func compact(
        _ turns: [SessionTranscriptTurn],
        policy: AgentConversationExportPolicy
    ) -> AgentConversationCompaction
}

/// Keeps the opening request and the most recent dialogue, shortening only when required.
nonisolated struct TailPreservingAgentConversationCompactor: AgentConversationCompacting {
    private static let framingReserve = 512
    private static let turnFramingCharacters = 16

    func compact(
        _ turns: [SessionTranscriptTurn],
        policy: AgentConversationExportPolicy
    ) -> AgentConversationCompaction {
        let eligible = turns.filter { policy.includes($0.role) && !$0.text.isEmpty }
        guard !eligible.isEmpty else {
            return AgentConversationCompaction(turns: [], omittedTurnCount: 0, shortenedTurnCount: 0)
        }

        let bodyBudget = max(256, policy.maximumCharacters - Self.framingReserve)
        if estimatedLength(of: eligible) <= bodyBudget {
            return AgentConversationCompaction(
                turns: renumbered(eligible),
                omittedTurnCount: 0,
                shortenedTurnCount: 0
            )
        }

        let firstUserIndex = eligible.firstIndex { $0.role == .user }
        let reservedHead = firstUserIndex.map { _ in
            min(policy.initialUserCharacterLimit, max(256, bodyBudget / 4))
        } ?? 0
        let tailBudget = max(128, bodyBudget - reservedHead - 96)

        var tail: [(index: Int, turn: SessionTranscriptTurn)] = []
        var remaining = tailBudget
        var shortenedCount = 0
        for index in eligible.indices.reversed() where index != firstUserIndex {
            let turn = eligible[index]
            let cost = estimatedLength(of: turn)
            if cost <= remaining {
                tail.append((index, turn))
                remaining -= cost
                continue
            }
            if tail.isEmpty, remaining > Self.turnFramingCharacters {
                tail.append((index, clipped(turn, characterLimit: remaining - Self.turnFramingCharacters)))
                shortenedCount += 1
            }
            break
        }
        tail.reverse()

        var kept: [(index: Int, turn: SessionTranscriptTurn)] = []
        if let firstUserIndex {
            let firstUser = eligible[firstUserIndex]
            let limit = max(1, reservedHead - Self.turnFramingCharacters)
            let clippedFirst = clipped(firstUser, characterLimit: limit)
            if clippedFirst.text != firstUser.text {
                shortenedCount += 1
            }
            kept.append((firstUserIndex, clippedFirst))
        }
        kept.append(contentsOf: tail)
        kept.sort { $0.index < $1.index }

        if kept.isEmpty, let last = eligible.last {
            kept = [(eligible.count - 1, clipped(last, characterLimit: bodyBudget - Self.turnFramingCharacters))]
            shortenedCount = 1
        }

        let uniqueIndices = Set(kept.map(\.index))
        return AgentConversationCompaction(
            turns: renumbered(kept.map(\.turn)),
            omittedTurnCount: max(0, eligible.count - uniqueIndices.count),
            shortenedTurnCount: shortenedCount
        )
    }

    private func estimatedLength(of turns: [SessionTranscriptTurn]) -> Int {
        turns.reduce(0) { $0 + estimatedLength(of: $1) }
    }

    private func estimatedLength(of turn: SessionTranscriptTurn) -> Int {
        turn.text.count + Self.turnFramingCharacters
    }

    private func clipped(_ turn: SessionTranscriptTurn, characterLimit: Int) -> SessionTranscriptTurn {
        guard characterLimit > 0, turn.text.count > characterLimit else { return turn }
        let marker = "\n…\n"
        let available = max(1, characterLimit - marker.count)
        let headCount = available / 2
        let tailCount = available - headCount
        let headEnd = turn.text.index(turn.text.startIndex, offsetBy: headCount)
        let tailStart = turn.text.index(turn.text.endIndex, offsetBy: -tailCount)
        return SessionTranscriptTurn(
            id: turn.id,
            role: turn.role,
            text: String(turn.text[..<headEnd]) + marker + String(turn.text[tailStart...])
        )
    }

    private func renumbered(_ turns: [SessionTranscriptTurn]) -> [SessionTranscriptTurn] {
        turns.enumerated().map { index, turn in
            SessionTranscriptTurn(id: index, role: turn.role, text: turn.text)
        }
    }
}

nonisolated protocol AgentConversationFormatting: Sendable {
    func format(
        _ compaction: AgentConversationCompaction,
        sourceDisplayName: String,
        maximumCharacters: Int
    ) -> String
}

/// Harness-neutral, human-readable transfer format suitable for one prompt argument.
nonisolated struct RoleLabeledAgentConversationFormatter: AgentConversationFormatting {
    func format(
        _ compaction: AgentConversationCompaction,
        sourceDisplayName: String,
        maximumCharacters: Int
    ) -> String {
        let introductionFormat = String(
            localized: "forkConversation.handoff.introduction",
            defaultValue: "The following conversation was transferred from %@. Continue the latest unfinished request using this context."
        )
        var sections = [String(format: introductionFormat, promptSafe(sourceDisplayName))]

        if compaction.omittedTurnCount > 0 || compaction.shortenedTurnCount > 0 {
            let compactionFormat = String(
                localized: "forkConversation.handoff.compacted",
                defaultValue: "Conversation compacted: %1$lld earlier turns omitted, %2$lld long turns shortened."
            )
            sections.append(String(
                format: compactionFormat,
                Int64(compaction.omittedTurnCount),
                Int64(compaction.shortenedTurnCount)
            ))
        }

        sections.append(contentsOf: compaction.turns.map { turn in
            "\(roleLabel(turn.role)):\n\(promptSafe(turn.text))"
        })
        let output = sections.joined(separator: "\n\n")
        guard output.count > maximumCharacters else { return output }
        let end = output.index(output.startIndex, offsetBy: maximumCharacters)
        return String(output[..<end])
    }

    private func roleLabel(_ role: SessionTranscriptRole) -> String {
        switch role {
        case .user:
            return String(localized: "forkConversation.handoff.role.user", defaultValue: "User")
        case .assistant:
            return String(localized: "forkConversation.handoff.role.assistant", defaultValue: "Assistant")
        case .system:
            return String(localized: "forkConversation.handoff.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "forkConversation.handoff.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "forkConversation.handoff.role.event", defaultValue: "Event")
        }
    }

    /// Removes terminal control bytes while preserving tabs, newlines, and Unicode text.
    private func promptSafe(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || (scalar.value >= 32 && scalar.value != 127)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Converts any supported source harness into one target-ready message.
nonisolated struct AgentConversationExportService: Sendable {
    static let live = AgentConversationExportService()

    let readerRegistry: AgentConversationReaderRegistry
    let compactor: any AgentConversationCompacting
    let formatter: any AgentConversationFormatting
    let policy: AgentConversationExportPolicy

    init(
        readerRegistry: AgentConversationReaderRegistry = .live,
        compactor: any AgentConversationCompacting = TailPreservingAgentConversationCompactor(),
        formatter: any AgentConversationFormatting = RoleLabeledAgentConversationFormatter(),
        policy: AgentConversationExportPolicy = AgentConversationExportPolicy()
    ) {
        self.readerRegistry = readerRegistry
        self.compactor = compactor
        self.formatter = formatter
        self.policy = policy
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    func message(for snapshot: SessionRestorableAgentSnapshot) async throws -> String {
        let turns = try await readerRegistry.read(AgentConversationSource(snapshot: snapshot))
        let compaction = compactor.compact(turns, policy: policy)
        guard !compaction.turns.isEmpty else {
            throw AgentConversationExportError.emptyConversation
        }
        return formatter.format(
            compaction,
            sourceDisplayName: snapshot.agentDisplayName,
            maximumCharacters: policy.maximumCharacters
        )
    }
}

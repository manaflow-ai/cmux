import Foundation

/// Pure, session-scoped clipboard operations used by the native action bridge. The caller owns the
/// focused-chat predicate and writes the returned text only after this predicate still holds.
public enum AgentChatCopyOutcome: Sendable, Equatable {
    case copied(String)
    case stale
    case missing
    case failed
}

public struct AgentChatCopyOperations {
    public init() {}
    @MainActor public static func name(info: @escaping () async -> [String: Any]?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        let value = await info()?.string("name")
        guard isCurrent() else { return .stale }
        return value.flatMap({ $0.isEmpty ? nil : $0 }).map(AgentChatCopyOutcome.copied) ?? .missing
    }

    @MainActor public static func harnessSessionID(info: @escaping () async -> [String: Any]?, fallback: String?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        let metadata = await info()
        let value = metadata?.string("agentSessionId") ?? metadata?.string("agent_session_id") ?? fallback
        guard isCurrent() else { return .stale }
        return value.flatMap({ $0.isEmpty ? nil : $0 }).map(AgentChatCopyOutcome.copied) ?? .missing
    }

    @MainActor public static func conversation(_ read: @escaping () async throws -> String?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        do {
            let value = try await read()
            guard isCurrent() else { return .stale }
            return value.flatMap({ $0.isEmpty ? nil : $0 }).map(AgentChatCopyOutcome.copied) ?? .missing
        } catch { return .failed }
    }

    @MainActor public static func workingDirectory(info: @escaping () async -> [String: Any]?, fallback: String?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        let value = await info()?.string("cwd") ?? fallback
        guard isCurrent() else { return .stale }
        return value.flatMap({ $0.isEmpty ? nil : $0 }).map(AgentChatCopyOutcome.copied) ?? .missing
    }

    @MainActor public static func host(_ value: String?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        guard isCurrent() else { return .stale }
        return value.flatMap({ $0.isEmpty ? nil : $0 }).map(AgentChatCopyOutcome.copied) ?? .missing
    }

    @MainActor public static func details(info: @escaping () async -> [String: Any]?, files: @escaping () async -> [String: Any]?,
                                          identifier: String, fallbackHarnessSessionID: String?, fallbackCWD: String?, host: String?,
                                          isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        guard let metadata = await info() else { return .missing }
        let paths = AgentChatCopyText.files(from: await files())
        guard isCurrent() else { return .stale }
        let name = metadata.string("name")
        let harness = metadata.string("agentSessionId") ?? metadata.string("agent_session_id") ?? fallbackHarnessSessionID
        let cwd = metadata.string("cwd") ?? fallbackCWD
        return .copied(AgentChatCopyText.details(name: name, identifier: identifier, harnessSessionID: harness,
                                                 cwd: cwd, host: host, files: paths))
    }

    /// Every session file path the daemon names, one labelled row each.
    @MainActor public static func filePaths(files: @escaping () async -> [String: Any]?, isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        let text = AgentChatCopyText.paths(AgentChatCopyText.files(from: await files()))
        guard isCurrent() else { return .stale }
        return text.isEmpty ? .missing : .copied(text)
    }

    /// The contents of the first session file whose kind is in `kinds` (in the caller's order, so
    /// "claude_config" before "codex_config"). `.missing` when the daemon names none of them,
    /// `.failed` when the named file cannot be read as text.
    @MainActor public static func fileContents(files: @escaping () async -> [String: Any]?, kinds: [String],
                                               read: @escaping (String) async -> String?,
                                               isCurrent: @escaping @MainActor () -> Bool) async -> AgentChatCopyOutcome {
        let named = AgentChatCopyText.files(from: await files())
        guard let file = kinds.lazy.compactMap({ kind in named.first { $0.kind == kind } }).first else {
            return isCurrent() ? .missing : .stale
        }
        let text = await read(file.path)
        guard isCurrent() else { return .stale }
        guard let text else { return .failed }
        return text.isEmpty ? .missing : .copied(text)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
}

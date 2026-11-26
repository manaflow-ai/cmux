public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextBridge
public import CmuxNextDaemon
import Foundation

/// Rename Agent Session… on the focused chat: acpmux `_acpmux/rename`, the session's own name
/// (`cmux agent ls`, `HOST/NAME`, the CLI's `cmux agent session rename`). Rename Tab only
/// retitles the tab. Leo, 2026-11-20: "we need to honestly like rename the VMs that we have, and
/// then like rename the sessions that we have".
@MainActor
public struct AgentChatRename {
    public let environment: AcpmuxEnvironment
    public let turns: AgentTurnStateStore

    public init(environment: AcpmuxEnvironment, turns: AgentTurnStateStore) {
        self.environment = environment
        self.turns = turns
    }

    /// Whether the chat runs on this Mac's acpmux (the only one this app can rename it on).
    public func isLocal(_ chat: AgentSessionRef) -> Bool { chat.session != nil && turns.isMuted(chat) != nil }

    /// The name the ask starts from: the given name, else the session name, else the title.
    public func currentName(_ chat: AgentSessionRef) -> String {
        turns.displayName(for: chat) ?? turns.sessionName(for: chat) ?? turns.title(for: chat) ?? ""
    }

    /// Renames the chat's session. False when it is not a chat of this Mac's acpmux.
    public func rename(_ chat: AgentSessionRef, to name: String) async throws -> Bool {
        guard let session = chat.session, isLocal(chat) else { return false }
        try await environment.rename(session: session, newName: name)
        return true
    }

    public static let action: ActionID = "agentChat.renameSession"

    /// The action on the focused chat (`chat`, this Mac's acpmux at `environment`): with no name it
    /// asks for one, starting from the current name; with one it renames the session.
    public static func effect(_ registry: ActionRegistry, _ invocation: ActionInvocation,
                              environment: AcpmuxEnvironment?, chat: AgentSessionRef?) -> ActionEffect {
        guard let environment, let chat else { return .refused(notAChat) }
        let renamer = AgentChatRename(environment: environment, turns: .shared)
        guard renamer.isLocal(chat) else { return .refused(notAChat) }
        guard let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            _ = registry.ask(action, invocation, ActionArgumentAsk(argument: "name", initialText: renamer.currentName(chat)))
            return .done
        }
        // action-wait-allow: the session has its new name only once the acpmux daemon answers
        return .waiting(.externalProcess) {
            do { return try await renamer.rename(chat, to: name) ? nil : ActionWorkFailure(notAChat) } catch { return ActionWorkFailure(failed) }
        }
    }

    static var notAChat: String {
        String(localized: "agentChat.renameSession.notAChat", defaultValue: "Only an agent chat on this Mac can be renamed.", bundle: .localizedModule)
    }
    static var failed: String {
        String(localized: "agentChat.renameSession.failed", defaultValue: "The agent session could not be renamed.", bundle: .localizedModule)
    }
}

import AppKit
import CmuxAgentConversation
import Foundation

/// A panel hosting the structured agent chat view for one resolved transcript.
///
/// Created from the tab context menu's "Open as Chat View" action (and on
/// session restore), it captures the resolved agent kind, session id, and
/// transcript URL so the hosted ``AgentChatView`` can read the transcript
/// independently of the source terminal's lifetime.
@MainActor
final class AgentChatPanel: Panel {
    let id: UUID
    let panelType: PanelType = .agentChat

    /// The agent kind selecting the transcript parser.
    let agentKind: AgentKind

    /// The agent session id backing this chat.
    let sessionId: String

    /// The resolved transcript file, or `nil` when none was found (the hosted
    /// view shows its empty state).
    let transcriptURL: URL?

    /// The conversation source the hosted chat view reads from.
    let conversationSource: LocalTranscriptConversationSource

    let displayTitle: String
    var displayIcon: String? { "bubble.left.and.bubble.right" }

    init(agentKind: AgentKind, sessionId: String, transcriptURL: URL?) {
        self.id = UUID()
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.transcriptURL = transcriptURL
        self.conversationSource = LocalTranscriptConversationSource(
            agentKind: agentKind,
            sessionId: sessionId,
            transcriptURL: transcriptURL
        )
        self.displayTitle = Self.title(agentKind: agentKind)
    }

    convenience init(resolution: AgentChatTranscriptResolver.Resolution) {
        self.init(
            agentKind: resolution.agentKind,
            sessionId: resolution.sessionId,
            transcriptURL: resolution.transcriptURL
        )
    }

    /// The localized tab title for the chat's agent kind.
    nonisolated static func title(agentKind: AgentKind) -> String {
        switch agentKind {
        case .claudeCode:
            return String(localized: "agentChat.panel.title.claudeCode", defaultValue: "Claude Code Chat")
        case .codex:
            return String(localized: "agentChat.panel.title.codex", defaultValue: "Codex Chat")
        case .unknown:
            return String(localized: "agentChat.panel.title.generic", defaultValue: "Agent Chat")
        }
    }

    func focus() {}

    func unfocus() {}

    func close() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

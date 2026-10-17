import CmuxAgentChat
import CmuxMobileShellModel
import SwiftUI

/// The coding agents offered by the native Chat surface.
enum MobileChatProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case openCode = "opencode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openCode: "OpenCode"
        }
    }

    var subtitle: String {
        switch self {
        case .codex: "OpenAI coding agent"
        case .claude: "Anthropic coding agent"
        case .openCode: "Open source coding agent"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "theatermasks"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .codex: .green
        case .claude: .orange
        case .openCode: .blue
        }
    }

    var builtInTemplateKind: MobileTaskBuiltInTemplateKind {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .openCode
        }
    }

    var chatAgentKind: ChatAgentKind {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .other(rawValue)
        }
    }

    static func resolve(_ kind: ChatAgentKind) -> Self {
        switch kind {
        case .codex: .codex
        case .claude: .claude
        case .other(let source):
            source.lowercased() == "opencode" ? .openCode : .openCode
        }
    }

    var defaultTemplate: MobileTaskTemplate {
        switch self {
        case .codex:
            MobileTaskTemplate(
                name: title,
                icon: "agent:codex",
                command: "codex -- \"$CMUX_TASK_PROMPT\"",
                builtInKind: .codex
            )
        case .claude:
            MobileTaskTemplate(
                name: title,
                icon: "agent:claude",
                command: "claude -- \"$CMUX_TASK_PROMPT\"",
                builtInKind: .claude
            )
        case .openCode:
            MobileTaskTemplate(
                name: title,
                icon: "agent:opencode",
                command: "opencode --prompt \"$CMUX_TASK_PROMPT\"",
                builtInKind: .openCode
            )
        }
    }
}

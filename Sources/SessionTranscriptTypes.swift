import AppKit

struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let role: SessionTranscriptRole
    let text: String
}

enum SessionTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case event

    var label: String {
        switch self {
        case .user:
            return String(localized: "sessionIndex.preview.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "sessionIndex.preview.role.assistant", defaultValue: "Agent")
        case .system:
            return String(localized: "sessionIndex.preview.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "sessionIndex.preview.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "sessionIndex.preview.role.event", defaultValue: "Event")
        }
    }

    var foregroundColor: NSColor {
        switch self {
        case .user: return .controlAccentColor
        case .assistant: return .systemGreen
        case .system: return .secondaryLabelColor
        case .tool: return .systemOrange
        case .event: return .secondaryLabelColor
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .user: return .controlAccentColor.withAlphaComponent(0.035)
        case .assistant: return .systemGreen.withAlphaComponent(0.035)
        case .system: return .labelColor.withAlphaComponent(0.025)
        case .tool: return .systemOrange.withAlphaComponent(0.035)
        case .event: return .labelColor.withAlphaComponent(0.02)
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .tool, .system:
            return 11
        case .user, .assistant, .event:
            return 12
        }
    }

    var usesMonospacedBodyFont: Bool {
        switch self {
        case .tool, .system:
            return true
        case .user, .assistant, .event:
            return false
        }
    }
}

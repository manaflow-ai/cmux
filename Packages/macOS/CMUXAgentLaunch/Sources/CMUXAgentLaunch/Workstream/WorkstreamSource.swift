import Foundation

/// The agent that produced a `WorkstreamItem`. The raw value matches the
/// `_source` field on the wire frame that cmux hooks and the OpenCode plugin
/// emit, and matches Vibe Island's source tag 1:1 so existing hook payloads
/// can flow through unchanged. Unknown wire values are retained separately
/// by ``WorkstreamItem/sourceID`` for persistence and migration.
public enum WorkstreamSource: String, Codable, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case pi
    case amp
    case cursor
    case opencode
    case gemini
    case grok
    case hermesAgent = "hermes-agent"
    case copilot
    case codebuddy
    case factory
    case qoder

    /// Parses a wire-frame `_source` string. Unknown sources fall back to
    /// `nil`; callers should persist the raw string separately when they want
    /// to surface out-of-band agents without widening this enum.
    public init?(wireName: String) {
        self.init(rawValue: wireName)
    }

    /// The agent's name as the Activity panel shows it ("Send to Codex").
    /// Brand names, so not localized.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .amp: return "Amp"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .hermesAgent: return "Hermes Agent"
        case .copilot: return "Copilot"
        case .codebuddy: return "CodeBuddy"
        case .factory: return "Factory"
        case .qoder: return "Qoder"
        }
    }
}

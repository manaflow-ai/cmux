import Foundation

/// The agent that produced a `WorkstreamItem`. The raw value matches the
/// `_source` field on the wire frame that cmux hooks and the OpenCode plugin
/// emit, and matches Vibe Island's source tag 1:1 so existing hook payloads
/// can flow through unchanged.
public enum WorkstreamSource: String, Codable, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case cursor
    case opencode
    case gemini
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
}

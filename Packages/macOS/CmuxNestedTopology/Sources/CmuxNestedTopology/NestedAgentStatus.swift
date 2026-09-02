import Foundation

/// Normalized agent presentation status retained alongside the provider raw value.
public enum NestedAgentStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Agent is actively working.
    case working
    /// Agent is idle / waiting for input.
    case idle
    /// Agent is blocked and needs attention.
    case blocked
    /// Agent finished its current task.
    case done
    /// Provider emitted an unrecognized status; see the retained raw string.
    case unknown

    /// Maps a provider raw status string into a normalized presentation value.
    ///
    /// Unknown future values become ``unknown``; the caller must retain the raw
    /// string separately. Empty / whitespace-only values are invalid.
    ///
    /// - Parameter providerRawStatus: Provider-emitted status token.
    /// - Returns: Normalized status, or `nil` when the raw value is empty.
    public static func normalized(from providerRawStatus: String) -> NestedAgentStatus? {
        let trimmed = providerRawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "working": return .working
        case "idle": return .idle
        case "blocked": return .blocked
        case "done": return .done
        default: return .unknown
        }
    }
}

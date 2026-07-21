/// The edge a bounded conversation window must preserve when it exceeds its memory cap.
public enum ConversationPageRetentionEdge: Sendable, Equatable {
    /// Infer the edge from the requested page and the currently retained range.
    case automatic
    /// Keep the oldest loaded entries, evicting newer entries first.
    case oldest
    /// Keep the newest loaded entries, evicting older entries first.
    case newest
}

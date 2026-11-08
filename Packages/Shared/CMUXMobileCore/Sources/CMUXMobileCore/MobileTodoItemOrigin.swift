/// The creator of a mobile checklist item.
public enum MobileTodoItemOrigin: String, Codable, CaseIterable, Sendable {
    /// A person created the item.
    case user
    /// An agent created the item.
    case agent
}

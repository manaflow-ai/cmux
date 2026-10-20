/// What the user does with a message request.
public enum HomeRequestAnswer: Hashable, Sendable {
    /// Join the conversation: it moves to the main list.
    case accept
    /// Hide the request. The sender is not told.
    case decline
    /// Hide the request and every later one from the same sender. The sender is not told.
    case block
}

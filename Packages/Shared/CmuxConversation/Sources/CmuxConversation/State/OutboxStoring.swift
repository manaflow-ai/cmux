/// Keeps messages sent from this device until the backend confirms them,
/// so they survive the app being closed and are sent again later.
///
/// Attachments are stored as references to the original files, not copies.
public protocol OutboxStoring: Sendable {
    /// The unconfirmed messages for one conversation key, in send order.
    /// - Parameter key: The conversation key (a tab or conversation id).
    /// - Returns: The stored messages.
    func load(key: String) async -> [OutgoingMessage]
    /// Replaces the unconfirmed messages for one conversation key.
    /// - Parameters:
    ///   - messages: The messages; empty removes the key.
    ///   - key: The conversation key.
    func save(_ messages: [OutgoingMessage], key: String) async
}

/// How the Home transcript shows an agent's running reply.
///
/// User, Oct 20: "drop per-token streaming". The Chief writes several short messages,
/// one `send` call each, and that is the streaming: each message shows only when it is
/// whole, like a person texting. While a turn runs, the author's typing dots show.
public enum HomeReplyDisplay: Sendable, Equatable {
    /// The default: the typing dots while a turn runs, each message only when it is posted whole.
    case wholeMessages
    /// The older growing bubble (MessagesLab's stream rows, ask 11), token by token.
    case streaming
}

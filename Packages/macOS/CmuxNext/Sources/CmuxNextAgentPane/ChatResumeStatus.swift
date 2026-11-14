/// What `/resume <ref>` (`chats.resume`) did: the page words every case but ``opened`` as an
/// inline refusal (webviews `resumeCommand.ts`).
enum ChatResumeStatus: String, Error, Sendable, Equatable {
    /// The chat opened (or a tab that already shows it came forward).
    case opened
    /// No chat on this Mac has that session id, id start or transcript path.
    case notFound
    /// Several chats' session ids start with the reference.
    case ambiguous
    /// The id start is too short to name a chat.
    case tooShort
    /// The chat index could not be asked (no daemon, an older acpmux, the index is starting).
    case unavailable

    /// The status of acpmux's `_acpmux/chat_resolve` answer `status` when it found no chat.
    init(resolveStatus: String?) {
        switch resolveStatus {
        case "notFound": self = .notFound
        case "ambiguous": self = .ambiguous
        case "tooShort": self = .tooShort
        default: self = .unavailable
        }
    }
}

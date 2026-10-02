public import Foundation

/// A mention inside a text part: a UTF-16 range naming a participant.
public nonisolated struct HomeMention: Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var participantID: String

    public init(start: Int, length: Int, participantID: String) {
        self.start = start
        self.length = length
        self.participantID = participantID
    }
}

/// State of an agent work item shown as a compact card.
public nonisolated enum HomeWorkStatus: String, Hashable, Sendable {
    case running, done, failed, waiting
}

/// One part of a message (home.md section 2 `Part`).
public nonisolated enum HomePart: Hashable, Sendable {
    case text(String, mentions: [HomeMention] = [])
    /// An agent session's work: the session name, its status and a one-line preview.
    case work(session: String, status: HomeWorkStatus, preview: String?)
    /// A part this renderer does not draw (attachment, link, poll): a one-line
    /// description shown in a muted bubble (MessagesLab MODEL.md fallback row).
    case fallback(String)

    /// Plain text for previews and copy.
    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .work(let session, _, let preview): preview.map { "\(session): \($0)" } ?? session
        case .fallback(let text): text
        }
    }
}

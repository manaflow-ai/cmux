public import CmuxHomeCore
import Foundation

// The owner's system rows besides a failed turn's (`failureSessionPrefix`): a failed turn's Try
// Again, the "Chief will remember" rows of saved memory notes, and a stopped turn's "Stopped".
extension ChiefConversationOwner {
    /// The session prefix of a saved memory note's work part (Home's `ChiefRows.memoryPrefix`, the
    /// same id; change both): `chief.memory:t:<note id>` for a note saved during a turn,
    /// `chief.memory:s:<note id>` for one saved outside a turn. Its title is the note; `.failed`
    /// once the note was forgotten through the row's Undo.
    public static let memorySessionPrefix = "chief.memory:"

    /// The session prefix of the quiet "Stopped" row a stopped turn posts (Home's
    /// `ChiefRows.stoppedPrefix`, the same id; change both): `chief.stopped:<uuid>`. Its title
    /// is the row's text in the user's language.
    public static let stoppedSessionPrefix = "chief.stopped:"

    /// The user stopped a turn (``stopTurn(conversation:)``): one quiet system row marks where the
    /// Chief's reply ends, after the turn's last message, in its thread.
    func postStoppedNotice(in conversation: ConversationID, author: ParticipantID, threadRoot: MessageID?) {
        let work = WorkRef(session: Self.stoppedSessionPrefix + UUID().uuidString.lowercased(), title: ChiefText.turnStopped,
                           status: .done, preview: nil)
        _ = try? commitMessage(in: conversation, author: author, parts: [.work(work)], key: .make(), threadRoot: threadRoot)
    }

    /// Runs the user's newest message of `conversation` again, as a new turn with the same text,
    /// pictures and thread (a failed turn's Try Again). No message is posted: the transcript keeps
    /// the user's message once.
    ///
    /// - Parameter conversation: The conversation.
    /// - Returns: False when a turn runs or waits there, or the user has no message to run again.
    @discardableResult
    public func retryLastTurn(conversation: ConversationID) -> Bool {
        guard running[conversation] == nil, pending[conversation]?.isEmpty ?? true, !stopping.contains(conversation),
              let state = conversations[conversation],
              let message = state.messages.last(where: { $0.author == me.id && $0.retractedAt == nil && !$0.parts.isEmpty }),
              let turn = try? pendingTurn(message.parts, threadRoot: message.threadRoot, in: state) else { return false }
        enqueue(turn, in: conversation)
        return true
    }

    /// A memory note was saved while `conversation` shows or works: its row says so in the
    /// transcript ("Chief will remember: …" either way). During a turn the row posts after the
    /// turn's last message; outside one, now. A note posts once per
    /// conversation, whichever view reported it.
    ///
    /// - Parameters:
    ///   - conversation: The conversation the row goes to.
    ///   - fact: The note's id (`m-…`).
    ///   - text: The note.
    public func noteMemorySaved(conversation: ConversationID, fact: String, text: String) {
        guard let state = conversations[conversation], memoryNoteMessage(fact, in: state) == nil else { return }
        if var turn = running[conversation] {
            guard !turn.memoryNotes.contains(where: { $0.fact == fact }) else { return }
            turn.memoryNotes.append((fact, text))
            running[conversation] = turn
            return
        }
        postMemoryNote(fact, text: text, duringTurn: false, in: conversation, author: state.chief?.id ?? chief.id)
    }

    /// The note `fact` was forgotten (its row's Undo): the row reads "Removed from memory".
    ///
    /// - Returns: Whether a row of `conversation` named the note.
    @discardableResult
    public func noteMemoryForgotten(conversation: ConversationID, fact: String) -> Bool {
        if var turn = running[conversation], let index = turn.memoryNotes.firstIndex(where: { $0.fact == fact }) {
            turn.memoryNotes.remove(at: index)
            running[conversation] = turn
            return true
        }
        guard let state = conversations[conversation], let messageID = memoryNoteMessage(fact, in: state) else { return false }
        _ = try? updateMessage(messageID, in: conversation) { message in
            message.parts = message.parts.map { part in
                guard case .work(var work) = part else { return part }
                work.status = .failed
                return .work(work)
            }
        }
        return true
    }

    func postMemoryNote(_ fact: String, text: String, duringTurn: Bool, in conversation: ConversationID, author: ParticipantID) {
        let session = Self.memorySessionPrefix + (duringTurn ? "t:" : "s:") + fact
        let work = WorkRef(session: session, title: text, status: .done, preview: nil)
        _ = try? commitMessage(in: conversation, author: author, parts: [.work(work)], key: .make(), threadRoot: nil)
    }

    /// The message of the row that names note `fact`, the newest.
    private func memoryNoteMessage(_ fact: String, in state: ChiefConversationState) -> MessageID? {
        let sessions = ["t:", "s:"].map { Self.memorySessionPrefix + $0 + fact }
        for message in state.messages.reversed() {
            for case .work(let work) in message.parts where sessions.contains(work.session) { return message.id }
        }
        return nil
    }
}

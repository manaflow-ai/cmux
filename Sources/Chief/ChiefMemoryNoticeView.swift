import AppKit
import CmuxChief
import CmuxHomeCore

/// The transcript's "Chief will remember: prefers 14 pt font · Undo" row (P1-5)
/// is a transcript row the owner posts (MessagesLab's `ChiefMemoryRowProvider`):
/// it scrolls with the conversation, so it never sits over the working line or
/// a bubble. This relay reports each note ``ChiefMemoryStore``'s file watcher
/// sees added (whoever wrote it: `cmux chief memory add` runs in Chief's turn)
/// to the owner, for the conversation whose turn saved it, or the one on screen
/// when no Chief works
/// (``ChiefService/noteMemorySaved(_:in:)``). The owner posts a note's row once,
/// after the turn's last message when one runs, at once otherwise; both read
/// "Chief will remember: …". Undo is on the row
/// (``ChiefService/undoMemory(_:in:)``).
@MainActor
final class ChiefMemoryNoticeRelay {
    private let conversation: ConversationID
    /// Whether the conversation is on screen now (the transcript view says).
    private let isShowing: () -> Bool
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init(conversation: ConversationID, isShowing: @escaping () -> Bool) {
        self.conversation = conversation
        self.isShowing = isShowing
        observer = NotificationCenter.default.addObserver(forName: ChiefMemoryStore.didChange, object: nil,
                                                          queue: .main) { [weak self] note in
            let added = note.userInfo?[ChiefMemoryStore.addedKey] as? [ChiefMemoryFact] ?? []
            MainActor.assumeIsolated { self?.memoryChanged(added: added) } // main-proof: observer on queue: .main
        }
        ChiefMemoryStore.shared.start()
    }

    // Not an isolated deinit (Swift 6.0 has none): removing the observer needs no actor.
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Stops following the memory (the transcript closed).
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func memoryChanged(added: [ChiefMemoryFact]) {
        // The turn that saved it, else (no Chief works anywhere: the user or a script saved it) the
        // conversation on screen.
        let service = ChiefService.shared
        guard observer != nil, !added.isEmpty,
              service.isWorking(conversation) || (service.workingConversations.isEmpty && isShowing()) else { return }
        let id = conversation
        // task-owner: one report per change; ends when the owner recorded the notes
        Task {
            for fact in added { await ChiefService.shared.noteMemorySaved(fact, in: id) }
        }
    }
}

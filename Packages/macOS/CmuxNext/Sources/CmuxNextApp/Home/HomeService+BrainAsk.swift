import CmuxNextDaemon
import Foundation

extension HomeService {
    /// A person's message in a conversation of the default Chief is an ask
    /// (cx-4io0o, hq-6d 2026-10-15): it starts this home's brain host when
    /// none runs, also after `cmux chief shutdown` (ChiefBrainKeeper). The
    /// rule reads the owner's committed message, not the Home composer, so a
    /// send from Home, the `cmux` CLI or a page gets the same answer. The
    /// daemon starts every other Chief's brain on the same rule
    /// (cmux-tui chief_brains.rs `woken_by`); the default Chief's host is
    /// this app's.
    func askBrain(after event: CmuxNextDaemon.ConversationEvent) {
        guard case .message(let message) = event.change, message.author != Self.mux.id,
              let summary = conversations.first(where: { $0.id == event.conversation }),
              summary.participants.contains(where: { $0.id == Self.mux.id }),
              summary.participants.first(where: { $0.id == message.author })?.kind == .human else { return }
        brain.ensure(asked: true)
    }
}

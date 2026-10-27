import Foundation

// My own typing indicator (plans/cmux-next/home-dm-group-chats/AUDIT.md item 9): the composer
// reports its text, the store tells the owner. The owner broadcasts it to the other members and
// drops an `on` repeated within its refresh interval (home-core `typingGate`, 3 s), and other
// clients expire an indicator that is not refreshed, so while I type an `on` goes out at most
// every `typingRefresh`, and an `off` goes out once the field is empty, after `typingIdle`
// without a change, or when I leave the conversation.
extension HomeStore {
    /// How often a held `on` is sent again while I keep typing (the owner's refresh interval).
    static let typingRefresh: Duration = .seconds(3)
    /// How long the field may sit unchanged before my typing ends (Messages parity: dots go
    /// when the writer pauses, though the draft stays).
    static let typingIdle: Duration = .seconds(5)

    /// The compose field of `conversation` now holds `text`. Whitespace alone is not typing.
    public func composing(_ text: String, in conversation: ConversationID) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stopTyping(in: conversation)
        } else {
            startTyping(in: conversation)
        }
    }

    /// Ends my typing in `conversation` (the field emptied, a send, the conversation closed).
    public func stopTyping(in conversation: ConversationID) {
        let timers = myTypingTimers.removeValue(forKey: conversation)
        timers?.refresh?.cancel()
        timers?.idle?.cancel()
        myTypingFresh.remove(conversation)
        guard myTyping.remove(conversation) != nil else { return }
        sendTyping(false, in: conversation)
    }

    private func startTyping(in conversation: ConversationID) {
        var timers = myTypingTimers[conversation] ?? (refresh: nil, idle: nil)
        timers.idle?.cancel()
        let clock = self.clock
        let idle = Self.typingIdle
        // A bounded, cancellable delay (the idle deadline itself), cancelled by the next change.
        timers.idle = Task { [weak self] in
            // wakeup-allow: deadline my typing ends `typingIdle` after the last change; the next change cancels it
            do { try await clock.sleep(for: idle, tolerance: HomeWakeLeeway(delay: idle).tolerance) } catch { return }
            self?.stopTyping(in: conversation)
        }
        if !myTypingFresh.contains(conversation) {
            myTypingFresh.insert(conversation)
            myTyping.insert(conversation)
            sendTyping(true, in: conversation)
            let refresh = Self.typingRefresh
            // A bounded, cancellable delay: the owner's refresh interval before the next `on` may go.
            timers.refresh = Task { [weak self] in
                // wakeup-allow: deadline the owner's refresh interval before the next `on`, once per `on` sent
                do { try await clock.sleep(for: refresh, tolerance: HomeWakeLeeway(delay: refresh).tolerance) } catch { return }
                self?.myTypingFresh.remove(conversation)
            }
        }
        myTypingTimers[conversation] = timers
    }

    private func sendTyping(_ on: Bool, in conversation: ConversationID) {
        // task-owner: one ephemeral typing frame; ends with the owner's answer (nothing to settle)
        Task { [weak self] in _ = try? await self?.perform(.setTyping(conversation: conversation, on: on)) }
    }
}

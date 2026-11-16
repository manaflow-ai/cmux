import Foundation

/// Toggle Terminal and Chat's draft on the chat face: the unsent draft goes with a swap, both ways
/// (Leo, 2026-11-12: two live views of one session, instant both ways). The page reads, takes and
/// puts the composer's text (`conversation/toggleDraft.ts`); what moves is Rust's (cmux-window-rules
/// `tabs::draft`, ``TerminalChatPlacing``). Each call takes the swap's one deadline, and a write the
/// page gets past it does nothing: a late write never changes a composer that already shows.
extension AgentPaneView {
    /// The composer holds text or chips, as the page last reported (`pane.composerFilled`): no
    /// page call, so a swap with an empty composer waits on nothing.
    public var toggleDraftFilled: Bool { model.composerFilled }

    /// The composer's text when it can leave as text (no chips, no inline tokens); nil when it
    /// cannot, or the page does not answer by `deadline`.
    public func toggleDraft(by deadline: ContinuousClock.Instant) async -> String? {
        await Self.answer(by: deadline) { [weak self] in
            (try? await self?.callPageScript("return window.cmuxAcpmuxBridge?.toggleDraft?.() ?? null;")) as? String
        }
    }

    /// Empties the composer if it still holds exactly `text`; false when it does not, or the page
    /// does not answer by `deadline`.
    public func toggleDraftTake(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool {
        await write("return window.cmuxAcpmuxBridge?.takeToggleDraft?.(text, until) ?? false;", text, by: deadline)
    }

    /// Puts `text` in an empty composer; false when it is not empty, or the page does not answer by
    /// `deadline`.
    public func toggleDraftPut(_ text: String, by deadline: ContinuousClock.Instant) async -> Bool {
        await write("return window.cmuxAcpmuxBridge?.putToggleDraft?.(text, until) ?? false;", text, by: deadline)
    }

    private func write(_ body: String, _ text: String, by deadline: ContinuousClock.Instant) async -> Bool {
        let left = ContinuousClock.now.duration(to: deadline) - Self.togglePlaceReplyMargin
        guard left > .zero else { return false }
        let until = (Date().timeIntervalSince1970 + Self.seconds(left)) * 1000
        return await Self.answer(by: deadline) { [weak self] in
            (try? await self?.callPageScript(body, arguments: ["text": text, "until": until])) as? Bool
        } ?? false
    }
}

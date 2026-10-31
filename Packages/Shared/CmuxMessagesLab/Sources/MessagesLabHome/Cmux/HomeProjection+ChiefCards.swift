import CmuxHomeCore
import Foundation

/// A Chief's cards (cmux issue 25830, ``HomeChiefCardRowProvider``): the state they show that no
/// message change carries, and their clicks.
extension HomeProjection: HomeChiefCardStateObserver {
    func chiefCardStateChanged() { refreshCards() }

    /// Each shown card row again with what only this side knows: the screenshot once HomeMedia has
    /// it, the chips a later person message said, a sign-in the Secure Store holds. A card that
    /// changed is replaced in place (`.cmuxSetParts`, no motion); the message's other parts stay as
    /// they are shown. Runs after every applied update (`refreshAttachments`) and when the Secure
    /// Store's sites change.
    func refreshCards() {
        guard !stopped, let store = controller.store, HomeChiefCardRowProvider.installed != nil else { return }
        let cards = shown.filter { item in
            !item.isRetracted && item.parts.contains { if case .card = $0 { return true } else { return false } }
        }
        guard !cards.isEmpty else { return }
        let summary = shownSummary
        let chosen = HomeChiefCards.chosen(in: shown) { !HomeMapping.isAgent($0, summary) }
        let stored = cardState?.storedSites ?? []
        for item in cards {
            let id = HomeMapping.id(item, aliases: aliases)
            guard let message = store.state.message(id) else { continue }
            let want = HomeMapping.projectedParts(item, summary: summary, media: core.media, links: core.links,
                                                  cards: HomeChiefCardContext(chosen: chosen[item.key] ?? [], stored: stored)).parts
            guard want.count == message.parts.count else { continue }
            let parts = zip(message.parts, want).map { have, new -> Part in
                if case let .custom(c) = new, c.kind == HomeChiefCardRowProvider.kind { return new }
                return have
            }
            if parts != message.parts { controller.dispatch(.cmuxSetParts(id, parts)) }
        }
    }

    /// A click on a card's control: Open browser goes to the host, a chip and a saved sign-in send a
    /// person message in this conversation.
    func chiefCardAction(_ action: HomeChiefCardAction, at ref: PartRef) {
        switch action {
        case .open(let target, let url):
            onChiefCardOpen?(target, url)
        case .choose(let text):
            sendCardMessage(text)
        case .addSignIn(let site, let url):
            onChiefSignIn?(site, url) { [weak self] saved in
                guard saved else { return }
                self?.sendCardMessage(HomeChiefCards.signInAddedMessage(site))
            }
        }
    }

    /// A person message with `text`, through the store's normal send (`HomeOp.sendMessage`): it
    /// shows as my message and wakes the Chief like a typed one.
    func sendCardMessage(_ text: String) {
        guard !stopped else { return }
        let homeStore = self.homeStore
        let op = HomeOp.sendMessage(conversation: conversation, parts: [.text(text)])
        // task-owner: one send; ends with the owner's answer
        Task { _ = try? await homeStore.perform(op) }
    }
}

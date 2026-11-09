import AppKit
import CmuxHomeCore

/// The failed-turn cards' view state (HomeTurnFailureRowProvider): Details open, Copy error done, and
/// whether Retry shows. The stateless mapping draws each card closed; this pass applies the state.
extension HomeProjection {
    /// The person's message a failed-turn card at `message` retries: the latest one before it the
    /// Chief can answer again (`canRetryChiefTurn`).
    func turnFailureRetryTarget(_ message: ID) -> ID? {
        guard let at = shown.firstIndex(where: { HomeMapping.id($0, aliases: aliases) == message }) else { return nil }
        for item in shown[..<at].reversed() where item.author == me {
            let id = HomeMapping.id(item, aliases: aliases)
            return canRetryChiefTurn(id) ? id : nil
        }
        return nil
    }

    func turnFailureAction(_ ref: PartRef, _ action: HomeTurnFailureRowProvider.Action) {
        guard !stopped, let store = controller.store,
              let message = store.state.conversation.messages.first(where: { $0.id == ref.messageId }),
              case .custom(let custom)? = message.parts[checked: ref.partIndex],
              let card = HomeTurnFailureRowProvider.payload(custom) else { return }
        var local = turnFailureCards[ref.messageId] ?? .init()
        switch action {
        case .retry:
            if let target = turnFailureRetryTarget(ref.messageId) { retryChiefTurn(target) }
        case .copy:
            copyText(card.detail)
            local.copied = true
        case .details:
            local.open.toggle()
        }
        turnFailureCards[ref.messageId] = local
        refreshTurnFailureStates()
    }

    /// Reapplies each shown card's state after an owner refresh (the mapping draws it closed).
    func refreshTurnFailureStates() {
        guard !stopped, let store = controller.store else { return }
        for message in store.state.conversation.messages {
            for (index, part) in message.parts.enumerated() {
                guard case .custom(let custom) = part, let card = HomeTurnFailureRowProvider.payload(custom) else { continue }
                var local = turnFailureCards[message.id] ?? .init()
                local.retry = turnFailureRetryTarget(message.id) != nil
                guard local != card.local,
                      let next = HomeTurnFailureRowProvider.custom(.init(title: card.title, detail: card.detail, local: local))
                else { continue }
                controller.dispatch(.setCustomPart(message.id, index, next))
            }
        }
    }
}

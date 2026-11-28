// cmux: Reply to Selection's card over the message box (plans/cmux-next/reply-to-selection-DESIGN.md). Not a vendored file.
import AppKit

extension HostView {
    /// The card appears: up from the field and in (0.22 s); under Reduce Motion it only fades in.
    func showQuoteCard(_ quote: ReplyQuote, from name: String?, onRemove: @escaping () -> Void) {
        let card = quoteCard ?? ReplyQuoteCardView()
        let isNew = quoteCard == nil
        card.onRemove = onRemove
        card.show(quote, from: name)
        guard isNew else { return }
        quoteCard = card
        addSubview(card, positioned: .below, relativeTo: paneHeader)
        card.alphaValue = 0
        let reduce = MessagesLabHomeView.reducesMotion
        if let demo { placeQuoteCard(above: demo.compose.fieldRect) }
        let rest = card.frame
        if !reduce { card.frame = rest.offsetBy(dx: 0, dy: 6) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
            if !reduce { card.animator().frame = rest }
        }
    }

    /// The card leaves with a short fade (the same under Reduce Motion: no movement).
    func hideQuoteCard() {
        guard let card = quoteCard else { return }
        quoteCard = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            card.animator().alphaValue = 0
        }, completionHandler: { card.removeFromSuperview() })
    }

    /// The card sits just above the field, as wide as it.
    func placeQuoteCard(above field: CGRect) {
        guard let card = quoteCard, field.width > 0 else { return }
        let h = card.height(width: field.width)
        let f = CGRect(x: field.minX, y: field.minY - ReplyQuoteCardView.gap - h, width: field.width, height: h).integral
        if card.frame != f, card.layer?.animation(forKey: "frameOrigin") == nil { card.frame = f }
    }
}

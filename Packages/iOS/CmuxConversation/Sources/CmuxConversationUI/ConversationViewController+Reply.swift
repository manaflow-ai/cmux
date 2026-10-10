#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Reply mode: the transcript blurs, the thread (root plus loaded replies)
/// renders sharp just above the composer, the composer reads "Reply", and
/// the header's trailing button becomes an X.
final class ReplyThreadOverlay: UIView {
    let blur = UIVisualEffectView(effect: nil)
    /// Darkens the blurred transcript so thread bubbles stand out (B05/B08).
    let dim = UIView()
    let content = UIScrollView()
    var contentHeight: CGFloat = 0
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.replyThread"
        addSubview(blur)
        dim.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.62) : UIColor.white.withAlphaComponent(0.45) }
        dim.alpha = 0
        addSubview(dim)
        addSubview(content)
        content.alwaysBounceVertical = true
        content.keyboardDismissMode = .interactive
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: content)
        let hitsMessage = content.subviews.contains { $0.frame.contains(point) && ($0 as? MessageCell)?.liftedContentFrame.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY).contains(point) == true }
        if !hitsMessage { onClose?() }
    }
}

extension ConversationViewController {
    var replyOverlay: ReplyThreadOverlay? {
        view.subviews.compactMap { $0 as? ReplyThreadOverlay }.first
    }

    func enterReplyMode(for message: ConversationMessage) {
        let rootID = message.replyToID ?? message.id
        openThread(rootID: rootID, replyTo: message)
    }

    func openThread(rootID: String, replyTo: ConversationMessage? = nil) {
        guard let root = store.message(id: rootID) else { return }
        replyTarget = replyTo ?? root
        let overlay = replyOverlay ?? {
            let overlay = ReplyThreadOverlay(frame: view.bounds)
            overlay.onClose = { [weak self] in self?.exitReplyMode() }
            view.insertSubview(overlay, belowSubview: composerContainer)
            return overlay
        }()
        overlay.frame = view.bounds
        overlay.blur.frame = overlay.bounds
        populate(overlay, rootID: rootID)
        composer.isReplyMode = true
        header.setTrailingMode(.close, animated: true)
        overlay.content.alpha = 0
        overlay.content.transform = CGAffineTransform(translationX: 0, y: 24)
        composer.textView.becomeFirstResponder()
        UIView.animate(withDuration: 0.37, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            overlay.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            overlay.dim.alpha = 1
            overlay.content.alpha = 1
            overlay.content.transform = .identity
        }
    }

    private func populate(_ overlay: ReplyThreadOverlay, rootID: String) {
        overlay.content.subviews.forEach { $0.removeFromSuperview() }
        let thread = store.messages.filter { $0.id == rootID || $0.replyToID == rootID }
        let models = ConversationRowBuilder.rows(store: store).compactMap { row -> MessageRowModel? in
            guard case var .message(model) = row, thread.contains(where: { $0.id == model.message.id }) else { return nil }
            // Inside the thread, replies render without their quote.
            model.replyQuote = nil
            model.showsTail = true
            model.showsSenderName = !model.isOutgoing
            model.showsAvatar = model.reservesAvatarColumn
            if model.footer != .notDelivered { model.footer = .none }
            model.message.replyCount = 0
            return model
        }
        overlay.contentHeight = 0
        let width = view.bounds.width
        var y: CGFloat = 0
        var cells: [MessageCell] = []
        for model in models {
            let cellLayout = MessageCellLayout.compute(model: model, width: width, margin: layoutMargin, text: layoutCache.attributedText(for: model))
            let cell = MessageCell(frame: CGRect(x: 0, y: y, width: width, height: cellLayout.height))
            cell.configure(model: model, layout: cellLayout, text: layoutCache.attributedText(for: model))
            overlay.content.addSubview(cell)
            cell.layoutIfNeeded()
            cells.append(cell)
            y += cellLayout.height + 10
        }
        overlay.contentHeight = y
        layoutReplyOverlay()
    }

    /// Keeps the thread bottom-aligned just above the composer as the keyboard moves.
    func layoutReplyOverlay() {
        guard let overlay = replyOverlay else { return }
        overlay.frame = view.bounds
        overlay.blur.frame = overlay.bounds
        overlay.dim.frame = overlay.bounds
        let width = view.bounds.width
        let y = overlay.contentHeight
        let headerBottom = header.frame.maxY
        let available = composerContainer.frame.minY - headerBottom - 12
        overlay.content.frame = CGRect(x: 0, y: headerBottom, width: width, height: available)
        overlay.content.contentSize = CGSize(width: width, height: y)
        let inset = max(0, available - y)
        overlay.content.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        overlay.content.contentOffset = CGPoint(x: 0, y: max(-inset, y - available))
    }

    func exitReplyMode() {
        guard let overlay = replyOverlay else { return }
        replyTarget = nil
        composer.isReplyMode = false
        header.setTrailingMode(isSelecting ? .close : .action, animated: true)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            overlay.blur.effect = nil
            overlay.dim.alpha = 0
            overlay.content.alpha = 0
        } completion: { _ in
            overlay.removeFromSuperview()
        }
    }
}
#endif

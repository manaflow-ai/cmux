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
    /// The bubble that lifts out of the transcript and settles back into it.
    var anchorMessageID: String?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.replyThread"
        content.accessibilityLabel = String(localized: "conversation.ax.replyTranscript", defaultValue: "Reply transcript", bundle: .module)
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

    override func accessibilityPerformEscape() -> Bool {
        onClose?()
        return true
    }

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

    /// `dragOffset` is how far a swipe-to-reply had carried the bubble, so
    /// the lifted copy leaves from exactly where the finger let go.
    func enterReplyMode(for message: ConversationMessage, dragOffset: CGFloat = 0) {
        let rootID = message.replyToID ?? message.id
        openThread(rootID: rootID, replyTo: message, dragOffset: dragOffset)
    }

    func openThread(rootID: String, replyTo: ConversationMessage? = nil, dragOffset: CGFloat = 0) {
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
        // The blurred transcript behind the thread is out of VoiceOver's reach.
        collectionView.accessibilityElementsHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: overlay.content)
        // The replied-to bubble is one continuous object: its sharp copy
        // starts exactly over the transcript bubble and rides up to the
        // composer while the rest of the thread fades in around it.
        let anchorID = (replyTo ?? root).id
        overlay.anchorMessageID = anchorID
        let others = overlay.content.subviews.filter { ($0 as? MessageCell)?.model?.message.id != anchorID }
        let chrome = threadOnlyChrome(of: anchorID, in: overlay)
        if let lift = transcriptOffset(of: anchorID, in: overlay) {
            overlay.content.alpha = 1
            overlay.content.transform = CGAffineTransform(translationX: lift.x + dragOffset, y: lift.y)
            others.forEach { $0.alpha = 0 }
            chrome.forEach { $0.alpha = 0 }
        } else {
            overlay.content.alpha = 0
            overlay.content.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: 24)
        }
        composer.textView.becomeFirstResponder()
        UIView.animate(withDuration: 0.37, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            overlay.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            overlay.dim.alpha = 1
            overlay.content.alpha = 1
            overlay.content.transform = .identity
            others.forEach { $0.alpha = 1 }
            chrome.forEach { $0.alpha = 1 }
        }
    }

    /// The sender name and avatar the thread shows on the anchor bubble but
    /// its transcript row doesn't (mid-run rows hide both); they fade so the
    /// lifted bubble matches its transcript row at both ends of the move.
    private func threadOnlyChrome(of messageID: String, in overlay: ReplyThreadOverlay) -> [UIView] {
        guard let copy = overlay.content.subviews.lazy.compactMap({ $0 as? MessageCell }).first(where: { $0.model?.message.id == messageID }),
              let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == messageID } else { return false } }),
              case let .message(source) = rows[index] else { return [] }
        var views: [UIView] = []
        if !source.showsSenderName, !copy.senderLabel.isHidden { views.append(copy.senderLabel) }
        if !source.showsAvatar, !copy.avatar.isHidden { views.append(copy.avatar) }
        return views
    }

    /// The translation that puts the overlay's copy of `messageID` exactly
    /// over its bubble in the transcript, or nil when that row isn't on screen.
    private func transcriptOffset(of messageID: String, in overlay: ReplyThreadOverlay) -> CGPoint? {
        guard let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == messageID } else { return false } }),
              let source = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? MessageCell,
              let sourceBubble = source.cellLayout?.contentFrame,
              let copy = overlay.content.subviews.lazy.compactMap({ $0 as? MessageCell }).first(where: { $0.model?.message.id == messageID }),
              let copyBubble = copy.cellLayout?.contentFrame else { return nil }
        let saved = overlay.content.transform
        overlay.content.transform = .identity
        defer { overlay.content.transform = saved }
        let from = source.convert(sourceBubble, to: view)
        let to = copy.convert(copyBubble, to: view)
        return CGPoint(x: from.minX - to.minX, y: from.minY - to.minY)
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
            configureAccessibility(cell, model: model)
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

    /// `settling` returns the bubble to its transcript row; a send passes
    /// false because the transcript scrolls to the new reply underneath, so
    /// the thread just fades as the reply flies in.
    func exitReplyMode(settling: Bool = true) {
        guard let overlay = replyOverlay else { return }
        replyTarget = nil
        composer.isReplyMode = false
        header.setTrailingMode(isSelecting ? .close : .action, animated: true)
        collectionView.accessibilityElementsHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        // The bubble settles back onto its transcript row as the blur clears;
        // with that row off screen the thread just fades.
        let settle = settling ? overlay.anchorMessageID.flatMap { transcriptOffset(of: $0, in: overlay) } : nil
        let others = overlay.content.subviews.filter { ($0 as? MessageCell)?.model?.message.id != overlay.anchorMessageID }
        let chrome = overlay.anchorMessageID.map { threadOnlyChrome(of: $0, in: overlay) } ?? []
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            overlay.blur.effect = nil
            overlay.dim.alpha = 0
            if let settle {
                overlay.content.transform = CGAffineTransform(translationX: settle.x, y: settle.y)
                others.forEach { $0.alpha = 0 }
                chrome.forEach { $0.alpha = 0 }
            } else {
                overlay.content.alpha = 0
            }
        } completion: { _ in
            overlay.removeFromSuperview()
        }
    }
}
#endif

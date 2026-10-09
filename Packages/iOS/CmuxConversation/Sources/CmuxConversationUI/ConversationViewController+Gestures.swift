#if canImport(UIKit)
import CmuxConversationCore
import UIKit

extension ConversationViewController: UIGestureRecognizerDelegate {
    func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        pan.delegate = self
        pan.name = "conversation.horizontalPan"
        collectionView.addGestureRecognizer(pan)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.4
        press.delegate = self
        collectionView.addGestureRecognizer(press)

        // Double-tap on a bubble: the tapback bar alone (Messages, iOS 26).
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        doubleTap.name = "conversation.doubleTap"
        collectionView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        // A tap on a bubble waits out a possible second tap; taps elsewhere
        // never reach the double-tap recognizer, so they are not delayed.
        tap.require(toFail: doubleTap)
        collectionView.addGestureRecognizer(tap)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.name == "conversation.doubleTap" else { return true }
        // Not while bubble text is selected: that tap only ends the selection, at once.
        return !isSelecting && textSelection == nil
            && messageCell(at: touch.location(in: collectionView), requireContentHit: true)?.model?.message.seq != nil
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.name == "conversation.horizontalPan" {
            guard !isSelecting, !touchBelongsToTextSelection(pan.location(in: collectionView)) else { return false }
            let velocity = pan.velocity(in: collectionView)
            // Only a rightward drag on a bubble within 18 degrees of
            // horizontal is a reply (ChatKit's CKSwipeToReplyRules); a left
            // drag belongs to the transcript's scroll pan (send times).
            return velocity.x > 0 && replySwipeCell(at: pan.location(in: collectionView), velocity: velocity) != nil
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            return !isSelecting && !touchBelongsToTextSelection(gestureRecognizer.location(in: collectionView))
                && messageCell(at: gestureRecognizer.location(in: collectionView), requireContentHit: true) != nil
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer
    }

    func messageCell(at point: CGPoint, requireContentHit: Bool) -> MessageCell? {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { return nil }
        guard requireContentHit else { return cell }
        let local = cell.convert(point, from: collectionView)
        return cell.liftedContentFrame.insetBy(dx: -4, dy: -4).contains(local) ? cell : nil
    }

    // MARK: Horizontal pan: right on a bubble = reply, left anywhere = timestamps

    @objc private func handleHorizontalPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: collectionView).x
        switch pan.state {
        case .began:
            if translation > 0, let cell = replySwipeCell(at: pan.location(in: collectionView), velocity: pan.velocity(in: collectionView)), let model = cell.model {
                replyDragRowID = model.rowID
                replyHapticFired = false
            } else {
                replyDragRowID = nil
            }
            // Recognition already consumed some travel; apply it at once.
            updateHorizontalPan(translation, velocity: pan.velocity(in: collectionView).x)
        case .changed:
            updateHorizontalPan(translation, velocity: pan.velocity(in: collectionView).x)
        case .ended, .cancelled, .failed:
            endHorizontalPan(committed: pan.state == .ended)
        default:
            break
        }
    }

    private func updateHorizontalPan(_ translation: CGFloat, velocity: CGFloat) {
        if let rowID = replyDragRowID {
            updateReplySwipe(rowID: rowID, translation: translation, velocity: velocity)
        }
    }

    private func endHorizontalPan(committed: Bool) {
        if let rowID = replyDragRowID {
            endReplySwipe(rowID: rowID, ended: committed)
        }
    }

    // MARK: Long press

    @objc private func handleLongPress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began,
              let cell = messageCell(at: press.location(in: collectionView), requireContentHit: true),
              let model = cell.model else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presentActions(for: model, cell: cell, mode: .menu)
    }

    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended,
              let cell = messageCell(at: tap.location(in: collectionView), requireContentHit: true),
              let model = cell.model else { return }
        presentActions(for: model, cell: cell, mode: .tapbacks)
    }

    // MARK: Taps

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: collectionView)
        if photoDrawer != nil {
            dismissPhotoDrawer()
            return
        }
        // A tap away from selected bubble text clears it, and does nothing else.
        if textSelection != nil {
            if !touchBelongsToTextSelection(point) { endTextSelection() }
            return
        }
        if !isSelecting, let indexPath = collectionView.indexPathForItem(at: point), indexPath.item < rows.count,
           case let .notice(notice) = rows[indexPath.item], notice.failure != nil {
            presentNotUnsent(messageID: notice.messageID)
            return
        }
        guard let cell = messageCell(at: point, requireContentHit: false), let model = cell.model else {
            return
        }
        let local = cell.convert(point, from: collectionView)
        if isSelecting {
            toggleSelection(model.rowID)
            return
        }
        if let failed = cell.cellLayout?.failedBadgeFrame, failed.insetBy(dx: -10, dy: -10).contains(local) {
            presentRetry(for: model)
            return
        }
        if let imageView = cell.imageViews.first(where: { !$0.isHidden && $0.image != nil && $0.bounds.contains($0.convert(point, from: collectionView)) }) {
            presentPhotoViewer(from: imageView)
            return
        }
        if !cell.reactionBadge.isHidden, cell.reactionBadge.frame.insetBy(dx: -6, dy: -6).contains(cell.shiftable.convert(local, from: cell)) {
            presentActions(for: model, cell: cell, mode: .reactionDetail)
            return
        }
        if handlePollTap(cell: cell, model: model, local: local) { return }
        if let caption = cell.cellLayout?.translationFrame, caption.insetBy(dx: 0, dy: -6).contains(cell.shiftable.convert(local, from: cell)) {
            store.translations.toggleOriginal(rowID: model.rowID)
            return
        }
        if let replies = cell.cellLayout?.repliesFrame, replies.contains(local) {
            openThread(rootID: model.message.id)
            return
        }
        if let quote = cell.cellLayout?.quoteFrame, quote.contains(local), let parent = model.message.replyToID {
            openThread(rootID: parent)
            return
        }
        if let textFrame = cell.cellLayout?.textFrame, textFrame.contains(local),
           let participantID: String = textAttribute(.conversationMention, in: model, at: cell.textLabel.convert(local, from: cell)) {
            presentMentionCard(participantID: participantID, at: point)
            return
        }
        if let card = cell.cellLayout?.linkCardFrame, card.contains(local), let preview = model.message.linkPreview {
            switch preview.state {
            case .tapToLoad: store.loadLinkPreview(messageID: model.message.id)
            case .loaded, .loading: UIApplication.shared.open(preview.url)
            }
            return
        }
        if let textFrame = cell.cellLayout?.textFrame, textFrame.contains(local), let url = link(in: model, at: cell.textLabel.convert(local, from: cell)) {
            UIApplication.shared.open(url)
        }
    }

    private func link(in model: MessageRowModel, at point: CGPoint) -> URL? {
        textAttribute(.conversationLink, in: model, at: point)
    }

    private func textAttribute<Value>(_ key: NSAttributedString.Key, in model: MessageRowModel, at point: CGPoint) -> Value? {
        let text = layoutCache.attributedText(for: model)
        guard text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: layoutCache.layout(for: model, width: collectionView.bounds.width, margin: layoutMargin).textFrame?.width ?? 0, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < text.length else { return nil }
        return text.attribute(key, at: index, effectiveRange: nil) as? Value
    }

    private func presentRetry(for model: MessageRowModel) {
        let sheet = UIAlertController(
            title: model.message.isScheduled
                ? String(localized: "conversation.sendLater.failedTryAgain", defaultValue: "Your scheduled message was not sent. Tap “Try Again” to schedule this message.", bundle: .module)
                : String(localized: "conversation.retry.title", defaultValue: "Your message was not delivered.", bundle: .module),
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), style: .default) { [weak self] _ in
            self?.store.retry(rowID: model.rowID)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module), style: .destructive) { [weak self] _ in
            self?.store.discardFailed(rowID: model.rowID)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        present(sheet, animated: true)
    }

    /// Tapping "(!) Not Unsent": Try Again while the two-minute window is
    /// open, otherwise just the explanation (ChatKit's two alerts).
    func presentNotUnsent(messageID: String) {
        guard let message = store.message(id: messageID), message.unsendFailed else { return }
        let title = String(localized: "conversation.notUnsent.title", defaultValue: "Message Not Unsent", bundle: .module)
        let alert: UIAlertController
        if store.canRetryUnsend(message) {
            alert = UIAlertController(
                title: title,
                message: String(localized: "conversation.notUnsent.retryBody", defaultValue: "The original message will still be visible.", bundle: .module),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), style: .default) { [weak self] _ in
                self?.store.retryUnsend(messageID: messageID)
            })
        } else {
            alert = UIAlertController(
                title: title,
                message: String(localized: "conversation.notUnsent.expiredBody", defaultValue: "Your message was not unsent. The original message will still be visible.", bundle: .module),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "conversation.notUnsent.ok", defaultValue: "OK", bundle: .module), style: .default))
        }
        present(alert, animated: true)
    }

    // MARK: Select mode

    func setSelecting(_ selecting: Bool, initial: String? = nil) {
        // Remember where the pressed message is so the keyboard leaving
        // doesn't carry it off screen.
        let anchorRow = initial.flatMap { indexPath(for: $0) }
        let anchorY = anchorRow.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame.minY }.map { $0 - collectionView.contentOffset.y }
        if selecting { view.endEditing(true) }
        endTextSelection()
        view.layoutIfNeeded()
        if let anchorRow, let anchorY, let frame = collectionView.layoutAttributesForItem(at: anchorRow)?.frame {
            collectionView.contentOffset.y = min(max(-collectionView.adjustedContentInset.top, frame.minY - anchorY), bottomOffset.y)
        }
        isSelecting = selecting
        selectedRowIDs = selecting ? Set([initial].compactMap { $0 }) : []
        header.setTrailingMode(selecting ? .cancel : (replyTarget != nil ? .close : .action), animated: true)
        // Messages swaps the back button for the trailing X while selecting.
        header.setBackHidden(selecting, animated: true)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            for case let cell as MessageCell in self.collectionView.visibleCells {
                cell.setSelectionMode(selecting, selected: self.selectedRowIDs.contains(cell.model?.rowID ?? ""), animated: false)
            }
        }
        setSelectionToolbar(visible: selecting)
    }

    func toggleSelection(_ rowID: String) {
        if selectedRowIDs.contains(rowID) { selectedRowIDs.remove(rowID) } else { selectedRowIDs.insert(rowID) }
        for tag in [Self.selectionTrashTag, Self.selectionForwardTag] {
            (view.viewWithTag(tag) as? UIButton)?.isEnabled = !selectedRowIDs.isEmpty
        }
        if let indexPath = indexPath(for: rowID), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
            cell.setSelectionMode(true, selected: selectedRowIDs.contains(rowID), animated: true)
        }
    }

    /// Messages' select-mode bar: the composer gives way to two glass circles,
    /// Delete at the leading edge and Forward at the trailing edge (48 pt,
    /// centers 52 pt in from each side, 4 pt above the composer's center line;
    /// measured on iOS 26.5 Messages).
    private func setSelectionToolbar(visible: Bool) {
        let tag = 4242
        if visible {
            guard view.viewWithTag(tag) == nil else { return }
            let bar = SelectionToolbarView()
            bar.tag = tag
            let size = Self.selectionButtonSize
            let trash = makeSelectionButton(
                symbol: "trash",
                label: String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module),
                tag: Self.selectionTrashTag
            ) { [weak self] button in self?.confirmDeleteSelection(from: button) }
            let forward = makeSelectionButton(
                symbol: "arrowshape.turn.up.right",
                label: String(localized: "conversation.select.forward", defaultValue: "Forward", bundle: .module),
                tag: Self.selectionForwardTag
            ) { [weak self] _ in self?.forwardSelection() }
            let width = view.bounds.width
            let centerY = composerContainer.convert(CGPoint(x: 0, y: composerContainer.bounds.midY), to: view).y - 4
            bar.frame = CGRect(x: 0, y: centerY - size / 2, width: width, height: size)
            bar.autoresizingMask = [.flexibleWidth]
            let inset = Self.selectionButtonCenterInset - size / 2
            trash.frame = CGRect(x: inset, y: 0, width: size, height: size)
            forward.frame = CGRect(x: width - inset - size, y: 0, width: size, height: size)
            forward.autoresizingMask = [.flexibleLeftMargin]
            // Without a New Message to hand the draft to, there is no Forward.
            forward.isHidden = onForward == nil
            bar.addSubview(trash)
            bar.addSubview(forward)
            bar.alpha = 0
            view.addSubview(bar)
            UIView.animate(withDuration: 0.25) {
                bar.alpha = 1
                self.composerContainer.alpha = 0
            }
        } else if let bar = view.viewWithTag(tag) {
            UIView.animate(withDuration: 0.25) {
                bar.alpha = 0
                self.composerContainer.alpha = 1
            } completion: { _ in bar.removeFromSuperview() }
        }
    }

    private static let selectionButtonSize: CGFloat = 48
    private static let selectionButtonCenterInset: CGFloat = 52

    /// One glass circle holding a symbol button.
    private func makeSelectionButton(symbol: String, label: String, tag: Int, action: @escaping (UIButton) -> Void) -> UIView {
        let glass = makeGlassView(cornerRadius: Self.selectionButtonSize / 2, interactive: true)
        glass.frame = CGRect(x: 0, y: 0, width: Self.selectionButtonSize, height: Self.selectionButtonSize)
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.tag = tag
        button.isEnabled = !selectedRowIDs.isEmpty
        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            action(button)
        }, for: .touchUpInside)
        button.frame = glass.contentView.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(button)
        return glass
    }

    static let selectionTrashTag = 4243
    static let selectionForwardTag = 4244

    /// Messages asks before deleting: one destructive "Delete N Messages"
    /// action, then the rows collapse and select mode ends.
    private func confirmDeleteSelection(from source: UIView) {
        let doomed = selectedRowIDs
        guard !doomed.isEmpty else { return }
        let title = doomed.count == 1
            ? String(localized: "conversation.select.deleteOne", defaultValue: "Delete Message", bundle: .module)
            : String(format: String(localized: "conversation.select.deleteMany", defaultValue: "Delete %lld Messages", bundle: .module), doomed.count)
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
            self?.deleteSelection(doomed)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }

    /// Select mode's confirmed delete: select mode ends and the rows collapse
    /// together (neighbors regroup in the same animation).
    func deleteSelection(_ rowIDs: Set<String>) {
        setSelecting(false)
        store.deleteLocally(rowIDs: rowIDs)
    }

    /// Forward: select mode ends and New Message opens with the picked
    /// messages, in transcript order.
    func forwardSelection() {
        let picked = rows.compactMap { row -> ConversationMessage? in
            guard case let .message(model) = row, selectedRowIDs.contains(model.rowID) else { return nil }
            return model.message
        }
        let draft = ConversationForwardDraft(messages: picked)
        guard !draft.isEmpty else { return }
        setSelecting(false)
        // The host opens New Message with the draft (see ConversationLabView).
        onForward?(draft)
    }
}

/// Lets touches between the two select-mode circles reach the transcript.
private final class SelectionToolbarView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}

extension MessageCell {
    /// Select mode: content slides right to reveal a leading selection circle.
    func setSelectionMode(_ selecting: Bool, selected: Bool, animated: Bool) {
        let circle: UIImageView
        if let existing = contentView.viewWithTag(77) as? UIImageView {
            circle = existing
        } else {
            circle = UIImageView()
            circle.tag = 77
            circle.contentMode = .scaleAspectFit
            contentView.addSubview(circle)
        }
        let apply = {
            let symbol = selected ? "checkmark.circle.fill" : "circle"
            circle.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            circle.tintColor = selected ? .systemBlue : .tertiaryLabel
            let frame = self.liftedContentFrame
            circle.frame = CGRect(x: selecting ? 10 : -30, y: frame.midY - 13, width: 26, height: 26)
            circle.alpha = selecting ? 1 : 0
            let isOutgoing = self.model?.isOutgoing ?? false
            // Incoming content makes room for the circle; outgoing stays put.
            self.selectionShift = selecting && !isOutgoing ? 42 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: apply)
        } else {
            apply()
        }
    }
}
#endif

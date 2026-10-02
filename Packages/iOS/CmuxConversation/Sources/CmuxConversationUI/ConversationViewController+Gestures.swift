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

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.name == "conversation.horizontalPan" {
            guard !isSelecting else { return false }
            let velocity = pan.velocity(in: collectionView)
            // Only a clearly horizontal drag; vertical scrolling stays native.
            return abs(velocity.x) > abs(velocity.y) * 1.3
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            return !isSelecting && messageCell(at: gestureRecognizer.location(in: collectionView), requireContentHit: true) != nil
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
            if translation > 0, let cell = messageCell(at: pan.location(in: collectionView), requireContentHit: false), let model = cell.model {
                replyDragRowID = model.rowID
                replyHapticFired = false
            } else {
                replyDragRowID = nil
            }
            // Recognition already consumed some travel; apply it at once.
            updateHorizontalPan(translation)
        case .changed:
            updateHorizontalPan(translation)
        case .ended, .cancelled, .failed:
            endHorizontalPan(committed: pan.state == .ended)
        default:
            break
        }
    }

    private func updateHorizontalPan(_ translation: CGFloat) {
        if let rowID = replyDragRowID {
            let raw = max(0, translation)
            // Rubber band beyond the commit threshold.
            let threshold: CGFloat = 60
            let offset = raw <= threshold ? raw : threshold + (raw - threshold) * 0.35
            replyDragOffset = min(offset, 110)
            if let indexPath = indexPath(for: rowID), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
                cell.replyDrag = replyDragOffset
            }
            if replyDragOffset >= threshold, !replyHapticFired {
                replyHapticFired = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if replyDragOffset < threshold {
                replyHapticFired = false
            }
        } else {
            let raw = max(0, -translation)
            let distance: CGFloat = 64
            let reveal = raw <= distance ? raw / distance : 1 + (raw - distance) / distance * 0.25
            setTimestampReveal(min(reveal, 1.2), animated: false)
        }
    }

    private func endHorizontalPan(committed: Bool) {
        if let rowID = replyDragRowID {
            let commit = replyDragOffset >= 60 && committed
            let cell = indexPath(for: rowID).flatMap { collectionView.cellForItem(at: $0) as? MessageCell }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                cell?.replyDrag = 0
            }
            replyDragRowID = nil
            replyDragOffset = 0
            if commit, case let .message(model)? = row(for: rowID) {
                enterReplyMode(for: model.message)
            }
        } else {
            setTimestampReveal(0, animated: true)
        }
    }

    func setTimestampReveal(_ reveal: CGFloat, animated: Bool) {
        timestampReveal = reveal
        let apply = {
            for cell in self.collectionView.visibleCells {
                (cell as? MessageCell)?.timestampReveal = reveal
            }
        }
        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            apply()
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

    // MARK: Taps

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: collectionView)
        if photoDrawer != nil {
            dismissPhotoDrawer()
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
        if !cell.reactionBadge.isHidden, cell.reactionBadge.frame.insetBy(dx: -6, dy: -6).contains(cell.shiftable.convert(local, from: cell)) {
            presentActions(for: model, cell: cell, mode: .reactionDetail)
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
        if let textFrame = cell.cellLayout?.textFrame, textFrame.contains(local), let url = link(in: model, at: cell.textLabel.convert(local, from: cell)) {
            UIApplication.shared.open(url)
        }
    }

    private func link(in model: MessageRowModel, at point: CGPoint) -> URL? {
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
        return text.attribute(.conversationLink, at: index, effectiveRange: nil) as? URL
    }

    private func presentRetry(for model: MessageRowModel) {
        let sheet = UIAlertController(
            title: String(localized: "conversation.retry.title", defaultValue: "Your message was not delivered.", bundle: .module),
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

    // MARK: Select mode

    func setSelecting(_ selecting: Bool, initial: String? = nil) {
        // Remember where the pressed message is so the keyboard leaving
        // doesn't carry it off screen.
        let anchorRow = initial.flatMap { indexPath(for: $0) }
        let anchorY = anchorRow.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame.minY }.map { $0 - collectionView.contentOffset.y }
        if selecting { view.endEditing(true) }
        view.layoutIfNeeded()
        if let anchorRow, let anchorY, let frame = collectionView.layoutAttributesForItem(at: anchorRow)?.frame {
            collectionView.contentOffset.y = min(max(-collectionView.adjustedContentInset.top, frame.minY - anchorY), bottomOffset.y)
        }
        isSelecting = selecting
        selectedRowIDs = selecting ? Set([initial].compactMap { $0 }) : []
        header.setTrailingMode(selecting || replyTarget != nil ? .close : .action, animated: true)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            for case let cell as MessageCell in self.collectionView.visibleCells {
                cell.setSelectionMode(selecting, selected: self.selectedRowIDs.contains(cell.model?.rowID ?? ""), animated: false)
            }
        }
        setSelectionToolbar(visible: selecting)
    }

    func toggleSelection(_ rowID: String) {
        if selectedRowIDs.contains(rowID) { selectedRowIDs.remove(rowID) } else { selectedRowIDs.insert(rowID) }
        if let indexPath = indexPath(for: rowID), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
            cell.setSelectionMode(true, selected: selectedRowIDs.contains(rowID), animated: true)
        }
    }

    private func setSelectionToolbar(visible: Bool) {
        let tag = 4242
        if visible {
            guard view.viewWithTag(tag) == nil else { return }
            let bar = UIView()
            bar.tag = tag
            let trash = makeGlassView(cornerRadius: 22, interactive: true)
            let share = makeGlassView(cornerRadius: 22, interactive: true)
            let trashButton = UIButton(type: .system)
            trashButton.setImage(UIImage(systemName: "trash"), for: .normal)
            trashButton.tintColor = .label
            trashButton.accessibilityLabel = String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module)
            let shareButton = UIButton(type: .system)
            shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
            shareButton.tintColor = .label
            shareButton.accessibilityLabel = String(localized: "conversation.select.share", defaultValue: "Share", bundle: .module)
            shareButton.addAction(UIAction { [weak self] _ in self?.shareSelection() }, for: .touchUpInside)
            trash.contentView.addSubview(trashButton)
            share.contentView.addSubview(shareButton)
            bar.addSubview(trash)
            bar.addSubview(share)
            let width = view.bounds.width
            let y = composerContainer.frame.minY
            bar.frame = CGRect(x: 0, y: y, width: width, height: composerContainer.frame.height)
            trash.frame = CGRect(x: ConversationTheme.composerSideInset, y: 0, width: 44, height: 44)
            share.frame = CGRect(x: width - ConversationTheme.composerSideInset - 44, y: 0, width: 44, height: 44)
            trashButton.frame = trash.bounds
            shareButton.frame = share.bounds
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

    private func shareSelection() {
        let texts = rows.compactMap { row -> String? in
            guard case let .message(model) = row, selectedRowIDs.contains(model.rowID) else { return nil }
            return model.message.text
        }
        guard !texts.isEmpty else { return }
        present(UIActivityViewController(activityItems: [texts.joined(separator: "\n")], applicationActivities: nil), animated: true)
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

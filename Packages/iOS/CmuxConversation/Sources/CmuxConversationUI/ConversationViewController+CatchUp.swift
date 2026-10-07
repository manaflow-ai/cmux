#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Messages' catch-up arrow: opening a conversation with unread messages
/// lands on the newest one and offers a glass up-arrow in the top-right
/// corner that jumps to the first unread message. It leaves once that
/// message has been on screen. The conversation counts as viewed (and every
/// arrival is read) while it is on screen in the foreground.
extension ConversationViewController {
    static let catchUpButtonSize: CGFloat = 36

    func installCatchUp() {
        let button = catchUpButton
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        button.isHidden = true
        button.accessibilityIdentifier = "conversation.catchUp"
        button.accessibilityLabel = String(localized: "conversation.catchUp.label", defaultValue: "Scroll to first unread message", bundle: .module)
        let glass = makeGlassView(cornerRadius: Self.catchUpButtonSize / 2, interactive: true)
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(glass)
        let arrow = UIImageView(image: UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
        arrow.tintColor = .systemBlue
        arrow.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(arrow)
        button.addTarget(self, action: #selector(catchUpTapped), for: .touchUpInside)
        view.insertSubview(button, belowSubview: header)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.catchUpButtonSize),
            button.heightAnchor.constraint(equalToConstant: Self.catchUpButtonSize),
            button.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            button.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            glass.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            glass.topAnchor.constraint(equalTo: button.topAnchor),
            glass.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            arrow.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
        ])
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateViewing() }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.setViewing(false) }
        }
    }

    /// Viewed = on screen (between appear and disappear) in an active app.
    func updateViewing() {
        let active = view.window?.windowScene?.activationState == .foregroundActive
        store.setViewing(isOnScreen && active)
    }

    /// Hides the arrow once the first unread message is at or below the top
    /// of the visible transcript; shows it while that message is above.
    func updateCatchUp() {
        guard store.catchUpMarker != nil, hasPositionedInitially else {
            setCatchUpVisible(false)
            return
        }
        if let target = store.catchUpTarget, let index = rowIndex[target.rowID], let frame = layout.frame(at: index) {
            let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            if frame.maxY > visibleTop {
                // Seen (or never hidden): nothing left to catch up on.
                store.dismissCatchUp()
                setCatchUpVisible(false)
                return
            }
        }
        // ChatKit: "A message that I sent is visible on screen. Do not show
        // catch up button." Replying there means the reader has caught up.
        if let marker = store.catchUpMarker, collectionView.indexPathsForVisibleItems.contains(where: { indexPath in
            guard indexPath.item < rows.count, case let .message(model) = rows[indexPath.item], model.isOutgoing else { return false }
            return (store.message(rowID: model.rowID)?.seq ?? .max) > marker
        }) {
            store.dismissCatchUp()
            setCatchUpVisible(false)
            return
        }
        setCatchUpVisible(true)
    }

    private func setCatchUpVisible(_ visible: Bool) {
        guard catchUpButton.isHidden == visible else { return }
        catchUpButton.isHidden = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.catchUpButton.alpha = visible ? 1 : 0
            self.catchUpButton.transform = visible ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            if self.catchUpButton.alpha == 0 { self.catchUpButton.isHidden = true }
        }
        if visible {
            catchUpButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.catchUpButton.transform = .identity
            }
        }
    }

    @objc private func catchUpTapped() {
        catchUpButton.isEnabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { [weak self] in
            guard let self else { return }
            let rowID = await self.store.loadCatchUpTarget()
            self.catchUpButton.isEnabled = true
            guard let rowID else { return }
            self.jumpToRow(rowID)
        }
    }

    /// Scrolls so the row sits just under the header (Messages shows the
    /// first unread message at the top of the transcript).
    func jumpToRow(_ rowID: String) {
        collectionView.layoutIfNeeded()
        guard let index = rowIndex[rowID], let frame = layout.frame(at: index) else { return }
        isPinnedToBottom = false
        let top = collectionView.adjustedContentInset.top
        let y = min(max(-top, frame.minY - top - 8), bottomOffset.y)
        store.dismissCatchUp()
        setCatchUpVisible(false)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    /// Lab hook: the catch-up arrow's state, `visible` / `hidden`.
    public var catchUpState: String { catchUpButton.isHidden || catchUpButton.alpha == 0 ? "hidden" : "visible" }

    /// Lab hook: taps the catch-up arrow.
    public func triggerCatchUp() { catchUpTapped() }

    /// The unread count of every other conversation, shown in the back button.
    public func setBackUnreadCount(_ count: Int) {
        backUnreadCount = count
        if let info = store.info { header.configure(info: info, meID: store.meID, unreadCount: count) }
    }
}
#endif

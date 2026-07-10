#if os(iOS)
import SwiftUI
import UIKit

extension TranscriptListViewController {
    var distanceFromBottom: CGFloat {
        max(0, collectionView.contentOffset.y - bottomRestOffset.y)
    }

    func configurePill() {
        let host = UIHostingController(rootView: ScrollToBottomPill(unreadCount: 0) { [weak self] in
            self?.scrollToBottom()
        })
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.alpha = 0
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        host.didMove(toParent: self)
        pillHost = host
        renderedPillUnreadCount = 0
    }

    func updatePillVisibility() {
        guard let host = pillHost else {
            return
        }
        if renderedPillUnreadCount != unreadCount {
            host.rootView = ScrollToBottomPill(unreadCount: unreadCount) { [weak self] in
                self?.scrollToBottom()
            }
            renderedPillUnreadCount = unreadCount
        }
        let targetAlpha: CGFloat = distanceFromBottom > 160 ? 1 : (distanceFromBottom <= 40 ? 0 : host.view.alpha)
        guard abs(host.view.alpha - targetAlpha) > 0.01 else {
            return
        }
        UIView.animate(withDuration: 0.18) {
            host.view.alpha = targetAlpha
        }
    }
}
#endif

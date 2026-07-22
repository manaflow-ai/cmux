#if os(iOS)
import SwiftUI
public import UIKit

extension TranscriptListViewController {
    static let scrollToBottomPillThreshold: CGFloat = 40

    /// Updates the transcript's reserved visual bottom chrome height.
    /// - Parameter height: Height obstructed by floating composer chrome.
    public func setBottomChromeHeight(_ height: CGFloat) {
        let height = pixelRounded(max(0, height))
        guard abs(bottomChromeHeight - height) > 0.5 else {
            return
        }
        bottomChromeHeight = height
        additionalSafeAreaInsets.bottom = height
        view.setNeedsLayout()
        updatePillBottomConstraint()
    }

    var distanceFromBottom: CGFloat {
        max(0, bottomRestOffset.y - collectionView.contentOffset.y)
    }

    func configurePill() {
        let chromeView = TranscriptChromePassthroughView()
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.backgroundColor = .clear
        chromeView.isUserInteractionEnabled = true
        chromeView.accessibilityIdentifier = "transcript.chrome.container"
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UITEST_CHROME_DEBUG"] == "1" {
            chromeView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.16)
        }
        #endif
        view.addSubview(chromeView)
        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: view.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let host = UIHostingController(rootView: ScrollToBottomPill(theme: currentTheme, unreadCount: 0) { [weak self] in
            self?.scrollToBottom()
        })
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.accessibilityIdentifier = "transcript.chrome.pill-host"
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UITEST_CHROME_DEBUG"] == "1" {
            host.view.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.28)
        }
        #endif
        host.view.alpha = 0
        host.view.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        addChild(host)
        chromeView.addSubview(host.view)
        let bottomConstraint = host.view.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -(bottomChromeHeight + 8)
        )
        NSLayoutConstraint.activate([
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomConstraint,
        ])
        host.didMove(toParent: self)
        pillChromeView = chromeView
        pillHost = host
        pillBottomConstraint = bottomConstraint
        renderedPillUnreadCount = 0
    }

    func updatePillBottomConstraint() {
        pillBottomConstraint?.constant = -(bottomChromeHeight + 8)
    }

    func updatePillVisibility() {
        guard let host = pillHost else {
            return
        }
        if renderedPillUnreadCount != unreadCount {
            host.rootView = ScrollToBottomPill(theme: currentTheme, unreadCount: unreadCount) { [weak self] in
                self?.scrollToBottom()
            }
            host.view.invalidateIntrinsicContentSize()
            host.view.setNeedsLayout()
            host.view.superview?.layoutIfNeeded()
            renderedPillUnreadCount = unreadCount
        }
        let targetAlpha: CGFloat = distanceFromBottom >= Self.scrollToBottomPillThreshold
            && !isAutoStickingToBottom
            ? 1
            : 0
        guard abs(host.view.alpha - targetAlpha) > 0.01 else {
            return
        }
        let animations = {
            host.view.alpha = targetAlpha
            if UIAccessibility.isReduceMotionEnabled {
                host.view.transform = .identity
            } else {
                host.view.transform = targetAlpha > 0
                    ? .identity
                    : CGAffineTransform(scaleX: 0.82, y: 0.82)
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.12, animations: animations)
        } else if targetAlpha > 0 {
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.76,
                initialSpringVelocity: 0.45,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: animations
            )
        } else {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: animations)
        }
    }

    func refreshPillTheme() {
        guard let host = pillHost else {
            return
        }
        host.rootView = ScrollToBottomPill(theme: currentTheme, unreadCount: unreadCount) { [weak self] in
            self?.scrollToBottom()
        }
        host.view.invalidateIntrinsicContentSize()
    }
}
#endif

#if canImport(UIKit)
import CMUXMobileCore
import Observation
import UIKit

@MainActor
final class ToastHostChrome {
    weak var overlay: ToastOverlayViewController?
    var keyboardInset: CGFloat = 0 {
        didSet { overlay?.keyboardInsetChanged() }
    }
}

@MainActor
final class ToastOverlayViewController: UIViewController, UIGestureRecognizerDelegate {
    private let center: ToastCenter
    private let chrome: ToastHostChrome
    private let haptics: MobileHapticFeedback
    private var card: ToastCardView?
    private var cardID: UUID?
    private var bumpCount = 0
    private var placement: Toast.Placement = .top
    private var verticalConstraint: NSLayoutConstraint?
    private var observationTask: Task<Void, Never>?
    private var dragStarted = false
    private(set) var interactiveRegion: CGRect?

    init(center: ToastCenter, chrome: ToastHostChrome, haptics: MobileHapticFeedback) {
        self.center = center
        self.chrome = chrome
        self.haptics = haptics
        super.init(nibName: nil, bundle: nil)
        chrome.overlay = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
        observeCenter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        publishInteractiveRegion()
    }

    func keyboardInsetChanged() {
        updateVerticalConstraint()
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    private func observeCenter() {
        withObservationTracking {
            _ = center.presented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPresentation()
                self.observeCenter()
            }
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        guard isViewLoaded else { return }
        guard let presented = center.presented else {
            dismissCard()
            return
        }
        if cardID == presented.toast.id, let card {
            card.configure(with: presented.toast)
            if bumpCount != presented.bumpCount {
                bumpCount = presented.bumpCount
                animateBump(card)
                emitFeedback(for: presented.toast.style, bump: true)
            }
            announce(presented.toast)
            publishInteractiveRegion()
            return
        }
        showCard(presented)
    }

    private func showCard(_ presented: ToastCenter.Presented) {
        card?.removeFromSuperview()
        cardID = presented.toast.id
        bumpCount = presented.bumpCount
        placement = presented.toast.placement
        let next = ToastCardView(toast: presented.toast) { [weak self] in
            guard let self, let id = self.cardID else { return }
            self.center.dismiss(id)
        }
        next.translatesAutoresizingMaskIntoConstraints = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        next.addGestureRecognizer(pan)
        view.addSubview(next)
        card = next
        NSLayoutConstraint.activate([
            next.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            next.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            next.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            next.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        updateVerticalConstraint()
        view.layoutIfNeeded()
        animateArrival(next)
        emitFeedback(for: presented.toast.style, bump: false)
        announce(presented.toast)
        publishInteractiveRegion()
    }

    private func updateVerticalConstraint() {
        guard let card else { return }
        verticalConstraint?.isActive = false
        if placement == .top {
            verticalConstraint = card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6)
        } else {
            verticalConstraint = card.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -(8 + chrome.keyboardInset)
            )
        }
        verticalConstraint?.isActive = true
    }

    private func animateArrival(_ card: UIView) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        card.alpha = 0
        card.transform = reduceMotion
            ? .identity
            : CGAffineTransform(translationX: 0, y: placement == .top ? -22 : 22).scaledBy(x: 0.86, y: 0.86)
        UIView.animate(
            withDuration: reduceMotion ? ToastMotion.reduceMotionDuration : ToastMotion.arrivalDuration,
            delay: 0,
            usingSpringWithDamping: reduceMotion ? 1 : ToastMotion.arrivalDamping,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            card.alpha = 1
            card.transform = .identity
        }
    }

    private func dismissCard() {
        guard let card else { return }
        let departingID = cardID
        let sign: CGFloat = placement == .top ? -1 : 1
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? ToastMotion.reduceMotionDuration
                : ToastMotion.departureDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            card.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled {
                card.transform = CGAffineTransform(translationX: 0, y: 12 * sign).scaledBy(x: 0.94, y: 0.94)
            }
        } completion: { [weak self, weak card] _ in
            guard let self, self.cardID == departingID else { return }
            card?.removeFromSuperview()
            self.card = nil
            self.cardID = nil
            self.interactiveRegion = nil
        }
    }

    private func animateBump(_ card: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animateKeyframes(
            withDuration: ToastMotion.bumpDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
                card.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) {
                card.transform = .identity
            }
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let card, let id = cardID else { return }
        let translation = recognizer.translation(in: view).y
        let sign: CGFloat = placement == .top ? -1 : 1
        let toward = translation * sign
        let dampedTranslation = toward >= 0
            ? translation
            : -28 * (1 - 1 / (1 + (-toward) / 28)) * sign
        switch recognizer.state {
        case .began:
            dragStarted = true
            center.beginInteraction(for: id)
        case .changed:
            let progress = min(1, max(0, toward) / 96)
            card.transform = CGAffineTransform(translationX: 0, y: dampedTranslation)
                .scaledBy(x: 1 - 0.04 * progress, y: 1 - 0.04 * progress)
            card.alpha = 1 - 0.25 * progress
        case .ended, .cancelled, .failed:
            if dragStarted { center.endInteraction(for: id) }
            dragStarted = false
            let projected = recognizer.velocity(in: view).y * sign
            if toward > 48 || projected > 420 {
                center.dismiss(id)
            } else {
                UIView.animate(
                    withDuration: 0.34,
                    delay: 0,
                    usingSpringWithDamping: 0.72,
                    initialSpringVelocity: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    card.transform = .identity
                    card.alpha = 1
                }
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func publishInteractiveRegion() {
        guard let card, let window = view.window else {
            interactiveRegion = nil
            return
        }
        interactiveRegion = card.convert(card.bounds, to: window)
    }

    private func emitFeedback(for style: Toast.Style, bump: Bool) {
        if bump {
            haptics.impact(style: .light)
            return
        }
        switch style {
        case .info:
            haptics.impact(style: .light)
        case .success:
            haptics.notification(.success)
        case .warning:
            haptics.notification(.warning)
        case .failure:
            haptics.notification(.error)
        }
    }

    private func announce(_ toast: Toast) {
        let text = [toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
#endif

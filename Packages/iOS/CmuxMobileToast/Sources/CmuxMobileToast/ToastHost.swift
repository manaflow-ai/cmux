public import CMUXMobileCore

#if canImport(UIKit)
import CmuxMobileSupport
public import UIKit

/// Zero-size UIKit mount point that discovers its `UIWindowScene` and owns the
/// independent toast window for that scene.
@MainActor
public final class ToastWindowMountView: UIView {
    private let coordinator: ToastWindowCoordinator

    public init(
        center: ToastCenter,
        haptics: MobileHapticFeedback = MobileHapticFeedback()
    ) {
        coordinator = ToastWindowCoordinator(center: center, haptics: haptics)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene {
            coordinator.windowSceneChanged(scene)
        }
    }

    public func teardown() {
        coordinator.teardown()
    }
}

@MainActor
private final class ToastWindowCoordinator {
    private let center: ToastCenter
    private let haptics: MobileHapticFeedback
    private let chrome = ToastHostChrome()
    private var window: ToastPassthroughWindow?
    private var keyboardObserver: (any NSObjectProtocol)?
    #if DEBUG
    private var debugTrigger: ToastDebugTrigger?
    #endif

    init(center: ToastCenter, haptics: MobileHapticFeedback) {
        self.center = center
        self.haptics = haptics
        observeKeyboard()
        #if DEBUG
        debugTrigger = ToastDebugTrigger(center: center)
        #endif
    }

    func windowSceneChanged(_ scene: UIWindowScene) {
        if let window, window.windowScene === scene { return }
        installWindow(in: scene)
    }

    private func installWindow(in scene: UIWindowScene) {
        window?.isHidden = true
        let controller = ToastOverlayViewController(center: center, chrome: chrome, haptics: haptics)
        let overlay = ToastPassthroughWindow(windowScene: scene)
        overlay.interactiveRegion = { [weak controller] in controller?.interactiveRegion }
        overlay.windowLevel = .alert
        overlay.backgroundColor = .clear
        overlay.rootViewController = controller
        overlay.isHidden = false
        window = overlay
    }

    func teardown() {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        keyboardObserver = nil
        #if DEBUG
        debugTrigger?.invalidate()
        debugTrigger = nil
        #endif
        window?.isHidden = true
        window = nil
    }

    private func observeKeyboard() {
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let transition = MobileKeyboardTransition(notification: notification) else { return }
            MainActor.assumeIsolated { self?.keyboardChanged(transition) }
        }
    }

    private func keyboardChanged(_ transition: MobileKeyboardTransition) {
        guard let hostView = window?.rootViewController?.view else { return }
        let overlap = transition.overlap(in: hostView)
        chrome.keyboardInset = max(0, overlap - hostView.safeAreaInsets.bottom)
    }
}

final class ToastPassthroughWindow: UIWindow {
    var interactiveRegion: (() -> CGRect?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let region = interactiveRegion?(), region.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif

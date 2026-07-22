public import SwiftUI

#if os(iOS)
internal import CmuxMobileSupport
internal import UIKit
#endif

public extension View {
    /// Installs the toast presentation layer for this view tree and injects
    /// `center` into the environment so any descendant can present through
    /// `@Environment(ToastCenter.self)`. Mount once at the app root.
    ///
    /// On iOS toasts render in their own passthrough window above the app's
    /// window level, so they float over sheets and full-screen covers while
    /// every touch outside the toast falls through to the app untouched.
    @ViewBuilder
    func toastHost(_ center: ToastCenter) -> some View {
        #if os(iOS)
        background(ToastWindowMounter(center: center))
            .environment(center)
        #else
        overlay(ToastOverlayRoot(center: center))
            .environment(center)
        #endif
    }
}

#if os(iOS)

/// Zero-size anchor that discovers the hosting `UIWindowScene` and hands it
/// to the coordinator, which owns the overlay window.
private struct ToastWindowMounter: UIViewRepresentable {
    let center: ToastCenter

    func makeCoordinator() -> ToastWindowCoordinator {
        ToastWindowCoordinator(center: center)
    }

    func makeUIView(context: Context) -> ToastWindowAnchorView {
        let view = ToastWindowAnchorView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onWindowSceneChanged = { [weak coordinator] scene in
            coordinator?.windowSceneChanged(scene)
        }
        return view
    }

    func updateUIView(_ uiView: ToastWindowAnchorView, context: Context) {}

    static func dismantleUIView(_ uiView: ToastWindowAnchorView, coordinator: ToastWindowCoordinator) {
        coordinator.teardown()
    }
}

private final class ToastWindowAnchorView: UIView {
    var onWindowSceneChanged: ((UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChanged?(window?.windowScene)
    }
}

/// Owns the overlay window and feeds keyboard overlap into the overlay so
/// bottom toasts ride above the keyboard (a separate window gets no keyboard
/// safe area of its own).
@MainActor
final class ToastWindowCoordinator {
    private let center: ToastCenter
    private let chrome = ToastHostChrome()
    private var window: ToastPassthroughWindow?
    private var keyboardObserver: (any NSObjectProtocol)?
    #if DEBUG
    private var debugTrigger: ToastDebugTrigger?
    #endif

    init(center: ToastCenter) {
        self.center = center
        observeKeyboard()
        #if DEBUG
        debugTrigger = ToastDebugTrigger(center: center)
        #endif
    }

    func windowSceneChanged(_ scene: UIWindowScene?) {
        // A transient nil (view briefly detached) keeps the window: tearing it
        // down mid-toast would eat the departure animation.
        guard let scene else { return }
        if let window, window.windowScene === scene { return }
        installWindow(in: scene)
    }

    private func installWindow(in scene: UIWindowScene) {
        window?.isHidden = true
        let host = UIHostingController(rootView: ToastOverlayRoot(center: center, chrome: chrome))
        host.view.backgroundColor = .clear
        // Keyboard avoidance is handled explicitly through `chrome`; opting
        // out here keeps the hosting view's own safe-area math deterministic.
        host.safeAreaRegions = .container
        let overlay = ToastPassthroughWindow(windowScene: scene)
        overlay.interactiveRegion = { [weak chrome = chrome] in chrome?.interactiveRegion }
        overlay.windowLevel = .alert
        overlay.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false
        window = overlay
    }

    func teardown() {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
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
            MainActor.assumeIsolated {
                self?.keyboardChanged(transition)
            }
        }
    }

    private func keyboardChanged(_ transition: MobileKeyboardTransition) {
        guard let hostView = window?.rootViewController?.view else { return }
        let overlap = transition.overlap(in: hostView)
        chrome.keyboardInset = max(0, overlap - hostView.safeAreaInsets.bottom)
    }
}

/// Full-screen window that swallows touches only inside the visible card's
/// published frame; everything else falls through to the app's own windows.
///
/// SwiftUI draws the card without dedicated UIViews, so `super.hitTest`
/// returns the hosting view for card and empty space alike — the geometry
/// gate is what distinguishes them.
final class ToastPassthroughWindow: UIWindow {
    /// The visible toast's window-space frame, `nil` when nothing is shown.
    var interactiveRegion: (() -> CGRect?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let region = interactiveRegion?(), region.contains(point) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

#endif

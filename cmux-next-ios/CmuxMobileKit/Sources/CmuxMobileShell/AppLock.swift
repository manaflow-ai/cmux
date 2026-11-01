#if os(iOS)
import CmuxMobileDesign
import LocalAuthentication
import SwiftUI
import UIKit

/// Settings → Require Face ID (audit B11): with the setting on, cmux opens
/// locked and locks again whenever it goes to the background; Face ID (or the
/// device passcode) unlocks it.
///
/// The lock lives in its own window above alerts (review M3), so it covers
/// sheets and full-screen covers too (an overlay on the root view sits below
/// anything the root presents). The same window is a privacy cover while
/// the scene is inactive (the app switcher), so its snapshot shows the lock,
/// not a sheet's content.
@MainActor
@Observable
final class AppLockController {
    /// Notification replies that need Face ID wait while it holds (PushReplies).
    private(set) var locked: Bool {
        didSet { if locked != oldValue { NotificationRouter.shared.appLocked = locked } }
    }
    private(set) var evaluating = false
    private(set) var enabled: Bool
    /// The scene is inactive or in the background (the app switcher, a system sheet).
    @ObservationIgnored private var inactive = false
    /// The scene went to the background since the last unlock attempt (or
    /// this is the launch): returning to the foreground then asks for Face ID
    /// once. Coming back from Face ID's own sheet (inactive, never in the
    /// background) asks nothing, so a Cancel stays cancelled (review m5).
    @ObservationIgnored private(set) var asksOnActivate: Bool
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Checks the owner (Face ID, else the passcode). `nil`: no passcode on this
    /// device, so nothing can check the owner and the lock cannot hold.
    @ObservationIgnored var authenticate: @MainActor () -> (@MainActor () async -> Bool)? = AppLockController.deviceOwner
    /// The notification router has the lock state (`publish`).
    @ObservationIgnored private var published = false
    /// The first `setEnabled` has told the reply buttons.
    @ObservationIgnored private var synced = false

    /// Side-effect-free: `AppLock` builds one on every body pass and SwiftUI
    /// keeps only the first, so a write here from a discarded copy would undo
    /// an unlock (issue 25687). The kept one publishes in `attach` or `setEnabled`.
    init(enabled: Bool) {
        self.enabled = enabled
        locked = enabled
        asksOnActivate = enabled
    }

    /// What the lock window shows: the lock, or the privacy cover while inactive.
    var covered: Bool { locked || (enabled && inactive) }

    /// The setting, on appear and on every change (`AppLock`).
    func setEnabled(_ on: Bool) {
        guard on != enabled || !synced else { return }
        synced = true
        if on != enabled {
            enabled = on
            // Turning it off unlocks; turning it on locks from the next background.
            if !on { locked = false }
        }
        publish()
        PushReplies.shared.setRequireFaceID(on)
        update()
    }

    /// Tells the router the lock state once; `locked`'s didSet sends every change after.
    private func publish() {
        guard !published else { return }
        published = true
        NotificationRouter.shared.appLocked = locked
    }

    /// The scene the app's content is in; the lock window joins it.
    func attach(_ scene: UIWindowScene) {
        guard self.scene !== scene else { return }
        // The window can attach before the first `setEnabled`; hold replies from here.
        publish()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        self.scene = scene
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneDeactivated() }
            },
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneEnteredBackground() }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneActivated() }
            },
        ]
        inactive = scene.activationState != .foregroundActive
        update()
        if scene.activationState == .foregroundActive { sceneActivated() }
    }

    func sceneDeactivated() {
        inactive = true
        update()
    }

    func sceneEnteredBackground() {
        inactive = true
        if enabled {
            locked = true
            asksOnActivate = true
        }
        update()
    }

    func sceneActivated() {
        inactive = false
        if locked, asksOnActivate {
            asksOnActivate = false
            unlock()
        }
        update()
    }

    /// Face ID, or the passcode; the lock button and the return from the background.
    func unlock() {
        guard locked, !evaluating else { return }
        guard let check = authenticate() else {
            locked = false
            update()
            return
        }
        evaluating = true
        Task { @MainActor in
            let passed = await check()
            evaluating = false
            if passed { locked = false }
            update()
        }
    }

    private static func deviceOwner() -> (@MainActor () async -> Bool)? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        return {
            (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock cmux")) ?? false
        }
    }

    // MARK: Window

    private func update() {
        if covered { show() } else { hide() }
    }

    private func show() {
        guard let scene else { return }
        let window = self.window ?? makeWindow(scene)
        if window.isHidden { window.isHidden = false }
        if locked, !window.isKeyWindow { window.makeKey() }
    }

    private func hide() {
        guard let window, !window.isHidden else { return }
        window.isHidden = true
        scene?.windows.first { $0 !== window && !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
    }

    private func makeWindow(_ scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        // Above alerts, so nothing the app presents shows through.
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockScreen(controller: self))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.accessibilityViewIsModal = true
        self.window = window
        return window
    }
}

struct AppLock: ViewModifier {
    let enabled: Bool
    @State private var controller: AppLockController

    init(enabled: Bool) {
        self.enabled = enabled
        _controller = State(initialValue: AppLockController(enabled: enabled))
    }

    func body(content: Content) -> some View {
        content
            .background(SceneReader { controller.attach($0) })
            .onChange(of: enabled, initial: true) { _, on in controller.setEnabled(on) }
    }
}

/// Reports the window scene its view lands in.
private struct SceneReader: UIViewRepresentable {
    let found: @MainActor (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) { view.found = found }

    final class ReaderView: UIView {
        var found: (@MainActor (UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}

private struct LockScreen: View {
    let controller: AppLockController

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("cmux is locked")
                    .font(.title3.weight(.semibold))
                if controller.locked {
                    Button { controller.unlock() } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                    }
                    // The app's primary capsule: the lock screen sits outside
                    // the shell's tint, where .borderedProminent drew system blue.
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary))
                    .disabled(controller.evaluating)
                    .accessibilityIdentifier("cmuxMobile.appLock.unlock")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmuxMobile.appLock")
    }
}

extension View {
    /// Locks the app behind Face ID while `enabled` (``AppLock``).
    func cmuxMobileAppLock(enabled: Bool) -> some View { modifier(AppLock(enabled: enabled)) }
}
#endif

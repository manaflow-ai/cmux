#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileToast
import Foundation
import Observation
import UIKit

/// UIKit composition root for the mobile app surface.
///
/// This controller owns every app-lifetime UI dependency explicitly. Child
/// controllers receive concrete stores and actions, and no presentation state
/// is resolved through a declarative environment.
@MainActor
public final class CMUXMobileAppViewController: UIViewController {
    private let coordinator: MobileRootCoordinator
    private let analytics: any AnalyticsEmitting
    private let browserStore: BrowserSurfaceStore
    private let browserStreamStore: BrowserStreamStore
    private let toastMount: ToastWindowMountView

    private var contentController: UIViewController?
    private var pairingController: UIViewController?
    private var observationGeneration: UInt64 = 0
    private var hasStarted = false

    public init(
        store: CMUXMobileShellStore,
        auth: AuthCoordinator,
        analytics: any AnalyticsEmitting,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        connectionMethodStore: MobileConnectionMethodStore,
        onboardingStore: MobileOnboardingStore,
        tailscaleStatusMonitor: (any TailscaleStatusObserving)?,
        irohSettingsController: (any CmxIrohSettingsControlling)? = nil,
        signOutHook: MobileSignOutHook,
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        browserStreamStore: BrowserStreamStore = BrowserStreamStore(),
        toastCenter: ToastCenter = ToastCenter(),
        prepareForDogfoodAttach: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.analytics = analytics
        self.browserStore = browserStore
        self.browserStreamStore = browserStreamStore
        self.toastMount = ToastWindowMountView(
            center: toastCenter,
            haptics: displaySettings.haptics
        )
        self.coordinator = MobileRootCoordinator(
            store: store,
            auth: auth,
            onboardingStore: onboardingStore,
            connectionMethodStore: connectionMethodStore,
            pushCoordinator: pushCoordinator,
            displaySettings: displaySettings,
            toastCenter: toastCenter,
            tailscaleStatusMonitor: tailscaleStatusMonitor,
            irohSettingsController: irohSettingsController,
            signOutHook: signOutHook,
            prepareForDogfoodAttach: prepareForDogfoodAttach
        )
        super.init(nibName: nil, bundle: nil)
        coordinator.stateDidChange = { [weak self] in
            self?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        toastMount.teardown()
    }

    public override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        toastMount.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toastMount)
        NSLayoutConstraint.activate([
            toastMount.widthAnchor.constraint(equalToConstant: 0),
            toastMount.heightAnchor.constraint(equalToConstant: 0),
            toastMount.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toastMount.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        view = root
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        coordinator.start()
        observeState()
        render()
    }

    public func sceneDidBecomeActive() {
        coordinator.sceneDidBecomeActive()
    }

    public func sceneWillResignActive() {
        coordinator.sceneWillResignActive()
    }

    public func open(_ url: URL) {
        coordinator.open(url)
    }

    private func observeState() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = coordinator.auth.isAuthenticated
            _ = coordinator.auth.isRestoringSession
            _ = coordinator.auth.currentUser?.id
            _ = coordinator.auth.resolvedTeamID
            _ = coordinator.onboardingStore.progress
            _ = coordinator.store.connectionState
            _ = coordinator.store.connectionError
            _ = coordinator.store.pairingVersionWarning
            _ = coordinator.store.hasActiveUnexpiredAttachTicket
            _ = coordinator.store.hasKnownPairedMac
            _ = coordinator.store.hasHiddenComputers
            _ = coordinator.store.isReconnectingStoredMac
            _ = coordinator.store.didFinishStoredMacReconnectAttempt
            _ = coordinator.store.workspaceListConnectionStatus
            _ = coordinator.store.workspaceTopologyVersion
            _ = coordinator.store.selectedWorkspaceID
            _ = coordinator.store.selectedTerminalID
            _ = coordinator.store.isComposerPresented
            _ = coordinator.store.activeTerminalTheme
            _ = coordinator.store.terminalConfigThemeGeneration
            _ = coordinator.store.notificationFeedItems
            _ = coordinator.store.notificationFeedStatus
            _ = coordinator.store.notificationFeedUnreadCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.coordinator.observedStateDidChange()
                self.observeState()
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        renderContent()
        renderPairing()
    }

    private func renderContent() {
        let next: UIViewController
        switch coordinator.presentation {
        case .onboarding:
            if let current = contentController as? MobileOnboardingViewController {
                current.update()
                return
            }
            next = MobileOnboardingViewController(
                coordinator: coordinator,
                analytics: analytics
            )
        case .signIn:
            if contentController is MobileSignInViewController { return }
            next = MobileSignInViewController(auth: coordinator.auth, analytics: analytics)
        case .disconnected:
            if let current = contentController as? MobileDisconnectedViewController {
                current.update()
                return
            }
            next = MobileDisconnectedViewController(coordinator: coordinator)
        case .workspaces(let isRestoringStoredMac):
            if let current = contentController as? MobileWorkspaceShellViewController {
                current.update(isRestoringStoredMac: isRestoringStoredMac)
                return
            }
            next = MobileWorkspaceShellViewController(
                store: coordinator.store,
                coordinator: coordinator,
                browserStore: browserStore,
                browserStreamStore: browserStreamStore,
                isRestoringStoredMac: isRestoringStoredMac
            )
        }
        installContentController(next)
    }

    private func installContentController(_ next: UIViewController) {
        let previous = contentController
        previous?.willMove(toParent: nil)
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(next.view, belowSubview: toastMount)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        next.didMove(toParent: self)
        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
        contentController = next
    }

    private func renderPairing() {
        if coordinator.isPairingPresented {
            let wantsScanner = coordinator.pairingPresentation.showsScanner
            if let pairingController,
               wantsScanner == (pairingController is MobilePairingScannerViewController) {
                (pairingController as? MobilePairingViewController)?.update()
                return
            }
            let controller: UIViewController = wantsScanner
                ? MobilePairingScannerViewController(coordinator: coordinator)
                : MobilePairingViewController(coordinator: coordinator, analytics: analytics)
            if let navigation = pairingController?.navigationController {
                pairingController = controller
                navigation.setViewControllers([controller], animated: true)
                return
            }
            guard presentedViewController == nil else { return }
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.selectedDetentIdentifier = .large
            }
            pairingController = controller
            present(navigation, animated: true)
        } else if let pairingController {
            self.pairingController = nil
            pairingController.navigationController?.dismiss(animated: true)
        }
    }
}
#endif

#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import CmuxMobileWorkspace
import Foundation

/// Owns mobile-root lifecycle and routing independently of its UIKit presentation.
///
/// The coordinator is the single owner of authentication mirroring, startup
/// reconnect arbitration, attach URLs, onboarding discovery, and scene
/// transitions. View controllers render its presentation and forward events;
/// they do not duplicate connection policy.
@MainActor
final class MobileRootCoordinator {
    enum Presentation: Equatable {
        case onboarding
        case signIn
        case disconnected
        case workspaces(isRestoringStoredMac: Bool)
    }

    private static let startupRestoringGate: Duration = .seconds(6)

    let store: CMUXMobileShellStore
    let auth: AuthCoordinator
    let onboardingStore: MobileOnboardingStore
    let connectionMethodStore: MobileConnectionMethodStore
    let pushCoordinator: MobilePushCoordinator
    let displaySettings: MobileDisplaySettings
    let toastCenter: ToastCenter
    let tailscaleStatusMonitor: (any TailscaleStatusObserving)?
    let irohSettingsController: (any CmxIrohSettingsControlling)?

    private let signOutHook: MobileSignOutHook
    private let prepareForDogfoodAttach: @MainActor @Sendable () async -> Void
    private let startupConnectionCoordinator = MobileStartupConnectionCoordinator()
    private let onboardingDiscovery = OnboardingMacDiscoveryKeepAlive()

    private(set) var isPairingPresented = false
    private(set) var pairingPresentation: PairingPresentation = .manual
    private(set) var isSceneActive = false
    private(set) var isAwaitingOnboardingReconnectStart = false
    private(set) var didExceedStartupRestoringGate = false
    private(set) var didAuthenticateWithAttachTicket = false
    private var pendingAttachURL: String?
    private var restoringGateTask: Task<Void, Never>?
    private var startupReconnectTask: Task<Void, Never>?
    private var signOutTask: Task<Void, Never>?
    private var hasStarted = false

    var stateDidChange: (@MainActor () -> Void)?

    init(
        store: CMUXMobileShellStore,
        auth: AuthCoordinator,
        onboardingStore: MobileOnboardingStore,
        connectionMethodStore: MobileConnectionMethodStore,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        toastCenter: ToastCenter,
        tailscaleStatusMonitor: (any TailscaleStatusObserving)?,
        irohSettingsController: (any CmxIrohSettingsControlling)?,
        signOutHook: MobileSignOutHook,
        prepareForDogfoodAttach: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.store = store
        self.auth = auth
        self.onboardingStore = onboardingStore
        self.connectionMethodStore = connectionMethodStore
        self.pushCoordinator = pushCoordinator
        self.displaySettings = displaySettings
        self.toastCenter = toastCenter
        self.tailscaleStatusMonitor = tailscaleStatusMonitor
        self.irohSettingsController = irohSettingsController
        self.signOutHook = signOutHook
        self.prepareForDogfoodAttach = prepareForDogfoodAttach
    }

    deinit {
        restoringGateTask?.cancel()
        startupReconnectTask?.cancel()
        signOutTask?.cancel()
    }

    var isAuthenticated: Bool {
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: auth.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication
        )
    }

    var presentation: Presentation {
        if onboardingStore.progress == .welcome {
            return .onboarding
        }
        if !isAuthenticated {
            return .signIn
        }
        if onboardingStore.progress == .connect {
            return .onboarding
        }

        let restoring = shouldShowRestoringStoredMac
        let disconnected = MobileAuthenticatedShellPresentation.resolve(
            connectionState: store.connectionState,
            hasKnownPairedMac: store.hasKnownPairedMac,
            hasHiddenComputers: store.hasHiddenComputers
        ) == .disconnected
        switch MobileRootAuthGate.shellSurface(
            connectionState: store.connectionState,
            showRestoringStoredMac: restoring,
            showDisconnectedNoPairedMacShell: disconnected
        ) {
        case .disconnectedNoKnownPairedMac:
            return .disconnected
        case .workspaceShell(let isRestoringStoredMac):
            return .workspaces(isRestoringStoredMac: isRestoringStoredMac)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        syncShellAuthentication()
        store.resumeForegroundRefresh()
        pushCoordinator.bind(store: store)
        reconnectStoredMacIfNeeded()
        updateOnboardingDiscovery()
        stateDidChange?()
    }

    func stop() {
        restoringGateTask?.cancel()
        restoringGateTask = nil
        startupReconnectTask?.cancel()
        startupReconnectTask = nil
        signOutTask?.cancel()
        signOutTask = nil
        store.suspendForegroundRefresh()
        hasStarted = false
    }

    /// Reconciles changes observed from the injected auth and shell stores.
    func observedStateDidChange() {
        syncShellAuthentication()
        if store.connectionState == .connected {
            isPairingPresented = false
        } else {
            clearAttachTicketAuthenticationIfNeeded()
        }
        pushCoordinator.workspacesDidChange()
        updateOnboardingDiscovery()
        if isAuthenticated, !auth.isRestoringSession {
            _ = consumePendingURLIfReady() || reconnectStoredMacIfNeeded()
        } else if !isAuthenticated {
            startupConnectionCoordinator.reset()
        }
        stateDidChange?()
    }

    func currentTeamDidChange() {
        store.currentTeamDidChange()
        updateOnboardingDiscovery()
        stateDidChange?()
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        store.resumeForegroundRefresh()
        tailscaleStatusMonitor?.refresh()
        updateOnboardingDiscovery()
        stateDidChange?()
        Task { [weak self] in
            guard let self else { return }
            await auth.revalidateSession()
            observedStateDidChange()
        }
    }

    func sceneWillResignActive() {
        isSceneActive = false
        store.suspendForegroundRefresh()
        updateOnboardingDiscovery()
        stateDidChange?()
    }

    func open(_ url: URL) {
        let rawURL = url.absoluteString
        if MobileRootAuthGate.isAttachURL(url) {
            connectAttachURL(rawURL)
            return
        }
        guard isAuthenticated else {
            pendingAttachURL = rawURL
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await store.connectPairingURL(rawURL)
            observedStateDidChange()
        }
    }

    func presentAddComputer() {
        presentPairing(.manual)
    }

    func presentPairingScanner(entry: PairingAnalyticsEntry) {
        presentPairing(.scanner(entry: entry))
    }

    func connectScannedPairingCode(_ code: String) {
        Task { [weak self] in
            guard let self else { return }
            let result = await store.connectPairingURLResult(
                code,
                userEnteredPairingCode: true
            )
            if result != .needsUserApproval {
                isPairingPresented = false
                pairingPresentation = .manual
            }
            observedStateDidChange()
        }
    }

    func dismissPairing() {
        isPairingPresented = false
        pairingPresentation = .manual
        if store.pairingVersionWarning != nil {
            cancelPairing()
        } else {
            clearAttachTicketAuthenticationIfNeeded()
        }
        stateDidChange?()
    }

    func cancelPairing() {
        store.cancelPairing()
        clearAttachTicketAuthenticationIfNeeded()
        stateDidChange?()
    }

    func completeOnboarding() {
        onboardingStore.markComplete()
        updateOnboardingDiscovery()
        stateDidChange?()
    }

    func markOnboardingReadyToConnect() {
        onboardingStore.markReadyToConnect()
        guard isAuthenticated, store.connectionState != .connected else {
            stateDidChange?()
            return
        }
        let stackUserID = auth.currentUser?.id
        isAwaitingOnboardingReconnectStart = true
        stateDidChange?()
        Task { [weak self] in
            guard let self else { return }
            defer {
                isAwaitingOnboardingReconnectStart = false
                stateDidChange?()
            }
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
        }
    }

    func retryAutomaticConnection() {
        let stackUserID = auth.currentUser?.id
        store.resumeForegroundRefresh()
        Task { [weak self] in
            guard let self else { return }
            await auth.revalidateSession()
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
            observedStateDidChange()
        }
    }

    func signOut() {
        guard signOutTask == nil else { return }
        signOutTask = Task { [weak self] in
            guard let self else { return }
            defer {
                signOutTask = nil
                stateDidChange?()
            }
            didAuthenticateWithAttachTicket = false
            didExceedStartupRestoringGate = false
            startupConnectionCoordinator.reset()
            toastCenter.dismissAll()
            store.signOut()
            let serverTeardown = signOutHook.begin()
            await auth.signOut(onSignedOut: serverTeardown)
        }
    }

    private var hasActiveAttachTicketAuthentication: Bool {
        didAuthenticateWithAttachTicket && store.hasActiveUnexpiredAttachTicket
    }

    private var shouldShowRestoringStoredMac: Bool {
        !didExceedStartupRestoringGate
            && store.workspaceListConnectionStatus != .connected
            && MobileRootAuthGate.shouldShowRestoringStoredMac(
                authenticated: isAuthenticated,
                connectionState: store.connectionState,
                isReconnectingStoredMac: store.isReconnectingStoredMac,
                hasKnownPairedMac: store.hasKnownPairedMac,
                pairedMacHintUndetermined: store.pairedMacHintUndetermined,
                didFinishStoredMacReconnectAttempt: store.didFinishStoredMacReconnectAttempt
            )
    }

    private func syncShellAuthentication() {
        if !isAuthenticated, !auth.isRestoringSession {
            toastCenter.dismissAll()
        }
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: isAuthenticated,
            isRestoringSession: auth.isRestoringSession,
            store: store
        )
    }

    @discardableResult
    private func reconnectStoredMacIfNeeded() -> Bool {
        guard isAuthenticated, !auth.isRestoringSession else { return false }
        if connectInjectedAttachURLIfNeeded() {
            return true
        }
        guard MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: auth.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
            isRestoringSession: auth.isRestoringSession,
            connectionState: store.connectionState
        ), let attempt = startupConnectionCoordinator.claimStoredReconnect() else {
            return false
        }

        didExceedStartupRestoringGate = false
        restoringGateTask?.cancel()
        restoringGateTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: Self.startupRestoringGate)
            guard let self, !Task.isCancelled, store.connectionState != .connected else { return }
            didExceedStartupRestoringGate = true
            stateDidChange?()
        }
        let stackUserID = auth.currentUser?.id
        startupReconnectTask?.cancel()
        startupReconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                restoringGateTask?.cancel()
                restoringGateTask = nil
                startupReconnectTask = nil
                startupConnectionCoordinator.finishStoredReconnect(attempt)
                stateDidChange?()
            }
            _ = await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
        }
        return true
    }

    private func presentPairing(_ presentation: PairingPresentation) {
        pairingPresentation = presentation
        isPairingPresented = true
        stateDidChange?()
    }

    private func connectAttachURL(_ rawURL: String) {
        guard !auth.isRestoringSession else {
            pendingAttachURL = rawURL
            return
        }
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication()
        stateDidChange?()
        Task { [weak self] in
            guard let self else { return }
            let result = await store.connectPairingURLResult(rawURL)
            if result == .needsUserApproval {
                presentAddComputer()
            }
            clearAttachTicketAuthentication(after: result)
            if result == .failed, store.connectionState != .connected {
                _ = reconnectStoredMacIfNeeded()
            }
            stateDidChange?()
        }
    }

    @discardableResult
    private func consumePendingURLIfReady() -> Bool {
        guard let rawURL = pendingAttachURL else { return false }
        if let url = URL(string: rawURL), MobileRootAuthGate.isAttachURL(url) {
            guard !auth.isRestoringSession else { return false }
            pendingAttachURL = nil
            connectAttachURL(rawURL)
            return true
        }
        guard isAuthenticated else { return false }
        pendingAttachURL = nil
        Task { [weak self] in
            guard let self else { return }
            await store.connectPairingURL(rawURL)
            if store.connectionState != .connected {
                _ = reconnectStoredMacIfNeeded()
            }
            stateDidChange?()
        }
        return true
    }

    private func clearAttachTicketAuthentication(after result: MobilePairingURLConnectionResult) {
        guard MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: result,
            connectionState: store.connectionState,
            hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
        ) else { return }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication()
    }

    private func clearAttachTicketAuthenticationIfNeeded() {
        guard didAuthenticateWithAttachTicket,
              store.connectionState != .connected || !store.hasActiveUnexpiredAttachTicket else {
            return
        }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication()
    }

    @discardableResult
    private func connectInjectedAttachURLIfNeeded() -> Bool {
        #if DEBUG
        guard isAuthenticated,
              let attachURL = UITestConfig.dogfoodAttachURL ?? UITestConfig.attachURL else {
            return false
        }
        guard let attempt = startupConnectionCoordinator.claimInjectedAttach() else {
            return true
        }
        Task { [weak self] in
            guard let self else { return }
            await prepareForDogfoodAttach()
            await store.connectPairingURL(attachURL)
            startupConnectionCoordinator.finishInjectedAttach(attempt)
            stateDidChange?()
        }
        return true
        #else
        return false
        #endif
    }

    private func updateOnboardingDiscovery() {
        let isDiscoveryAuthorized = auth.isAuthenticated
            && !auth.isRestoringSession
            && !hasActiveAttachTicketAuthentication
        let isStillEligible: @MainActor () -> Bool = { [store, onboardingStore] in
            onboardingStore.progress == .welcome
                && store.connectionState != .connected
        }
        #if DEBUG
        let hasInjectedAttachRoute = UITestConfig.dogfoodAttachURL != nil
            || UITestConfig.attachURL != nil
        #else
        let hasInjectedAttachRoute = false
        #endif
        onboardingDiscovery.update(
            isDiscoveryAuthorized: isDiscoveryAuthorized,
            accountKey: OnboardingDiscoveryAccountKey(
                userID: auth.currentUser?.id,
                teamID: auth.resolvedTeamID
            ),
            shouldKeepSearching: isStillEligible()
                && isSceneActive
                && !hasInjectedAttachRoute,
            isStillEligible: isStillEligible,
            coordinator: startupConnectionCoordinator,
            runAttempt: { [store, auth] in
                await store.reconnectActiveMacIfAvailable(
                    stackUserID: auth.currentUser?.id
                )
            }
        )
    }
}
#endif

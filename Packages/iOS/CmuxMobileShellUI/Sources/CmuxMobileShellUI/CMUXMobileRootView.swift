import Foundation
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CMUXMobileRootView: View {
    private static let startupRestoringGateSeconds: Double = 6

    @Bindable var store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(ToastCenter.self) private var toasts
    /// Optional so previews and hosts without the app root still render.
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?
    @Environment(\.dogfoodAttachPreparation) private var dogfoodAttachPreparation
    private let signOutHook: MobileSignOutHook
    private let startupConnectionCoordinator: MobileStartupConnectionCoordinator
    #if os(iOS)
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    /// Persists the last durable milestone in first-run onboarding.
    @Bindable private var onboardingStore: MobileOnboardingStore
    @State private var isAwaitingOnboardingReconnectStart = false
    @State private var onboardingMacDiscoveryKeepAlive = OnboardingMacDiscoveryKeepAlive()
    #endif
    @State private var pendingAttachURL: String?
    @State private var didAuthenticateWithAttachTicket = false
    @State private var didExceedStartupRestoringGate = false
    @State private var isShowingAddDeviceSheet = false
    @State private var pairingPresentation: PairingPresentation = .manual
    @State private var injectedAttachTask: Task<Void, Never>?
    @State private var injectedAttachTaskAttempt: MobileStartupConnectionCoordinator.Attempt?
    #if os(iOS)
    @State private var addDeviceSheetDetent: PresentationDetent = .large
    #endif
    /// The app's one tailnet detector, built at the composition root and
    /// injected through the environment so pairing, the disconnected shell,
    /// and future setup-help surfaces share the same signal. Re-evaluates on
    /// connectivity changes by itself; the scene-phase handler below covers
    /// foreground returns. `nil` when unwired (previews), which shows no
    /// Tailscale guidance.
    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor

    #if os(iOS)
    init(
        store: CMUXMobileShellStore,
        onboardingStore: MobileOnboardingStore,
        signOutHook: MobileSignOutHook,
        startupConnectionCoordinator: MobileStartupConnectionCoordinator
    ) {
        self.store = store
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
        self.startupConnectionCoordinator = startupConnectionCoordinator
    }
    #else
    init(
        store: CMUXMobileShellStore,
        signOutHook: MobileSignOutHook,
        startupConnectionCoordinator: MobileStartupConnectionCoordinator
    ) {
        self.store = store
        self.signOutHook = signOutHook
        self.startupConnectionCoordinator = startupConnectionCoordinator
    }
    #endif

    private var shouldShowTerminalLayoutPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.terminalLayoutPreviewEnabled
        #else
        return false
        #endif
    }

    private var shouldShowWorkspaceListLayoutPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.workspaceListLayoutPreviewEnabled
        #else
        return false
        #endif
    }

    private var shouldShowChangesPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.changesPreviewMode != nil
        #else
        return false
        #endif
    }

    private var shouldShowStreamingChatPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.streamingChatPreviewEnabled
        #else
        return false
        #endif
    }

    private var shouldShowHiddenComputersPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.hiddenComputersPreviewEnabled
        #else
        return false
        #endif
    }

    private var shouldShowOnboardingPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.onboardingPreviewEnabled
        #else
        return false
        #endif
    }

    private var shouldShowPushReadinessPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.pushReadinessPreviewState != nil
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// A configured launch attach route (dev/UITest auto-pair) owns startup
    /// connections outright; background onboarding discovery must not race it.
    private var hasInjectedAttachLaunchRoute: Bool {
        #if DEBUG
        UITestConfig.dogfoodAttachURL != nil || UITestConfig.attachURL != nil
        #else
        false
        #endif
    }
    #endif

    @ViewBuilder private var streamingChatPreview: some View {
        #if os(iOS) && DEBUG
        StreamingChatPreviewView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var terminalLayoutPreview: some View {
        #if os(iOS) && DEBUG
        TerminalLayoutPreviewView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var workspaceListLayoutPreview: some View {
        #if os(iOS) && DEBUG
        WorkspaceListLayoutPreviewView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var changesPreview: some View {
        #if os(iOS) && DEBUG
        ChangesPreviewView()
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var pushReadinessPreview: some View {
        #if os(iOS) && DEBUG
        MobilePushReadinessPreviewView(
            state: UITestConfig.pushReadinessPreviewState ?? "healthy"
        )
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var hiddenComputersPreview: some View {
        #if os(iOS) && DEBUG
        HiddenComputersPreviewView()
        #else
        EmptyView()
        #endif
    }

    var body: some View {
        rootContent
        .sheet(isPresented: addDeviceSheetBinding) {
            pairingSheet
        }
        .animation(.snappy(duration: 0.18), value: isAuthenticated)
        .animation(.snappy(duration: 0.18), value: store.phase)
        .onAppear {
            syncShellAuthentication(isAuthenticated)
            store.resumeForegroundRefresh()
            #if os(iOS)
            pushCoordinator.bind(store: store)
            #endif
            // If the view mounts already authenticated (cached session, or a
            // mock/fixture launch), `onChange(of: isAuthenticated)` never fires,
            // so kick off the stored-Mac reconnect here too. Without this the
            // workspace list's initial-connection status could never resolve
            // because nothing updates `didFinishStoredMacReconnectAttempt`.
            reconnectStoredMacIfNeeded()
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        .onDisappear {
            cancelInjectedAttachTask(retryLaunchRoute: true)
        }
        #if os(iOS)
        // A notification tap can arrive before the workspace (or terminal) it
        // targets is loaded (cold launch, or attach still in flight); re-apply
        // the parked deep link as the lists fill in. The version counter is a
        // cheap change signal: it bumps on any workspace or terminal list
        // mutation without allocating ID arrays on every body evaluation.
        .onChange(of: store.workspaceTopologyVersion) { _, _ in
            pushCoordinator.workspacesDidChange()
        }
        #endif
        .onChange(of: authManager.resolvedTeamID) { _, _ in
            // The effective team can change because the user selected one or
            // because launch-time team loading resolved the cached account's
            // default. Re-scope both transitions so a reconnect that began with
            // no team is superseded by exactly one current-team attempt.
            store.currentTeamDidChange()
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.resumeForegroundRefresh()
                // The user may have toggled Tailscale while we were backgrounded.
                tailscaleStatusMonitor?.refresh()
                // Re-check the Stack session on resume so one that died while
                // backgrounded routes to the sign-in page instead of waiting for a
                // failed connect to surface a confusing host-side message.
                Task { await authManager.revalidateSession() }
            } else {
                store.suspendForegroundRefresh()
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        .onOpenURL { url in
            let rawURL = url.absoluteString
            if MobileRootAuthGate.isAttachURL(url) {
                connectAttachURL(rawURL)
                return
            }

            guard isAuthenticated else {
                pendingAttachURL = rawURL
                return
            }
            Task {
                await store.connectPairingURL(rawURL)
            }
        }
        .onChange(of: isAuthenticated) { _, isAuthenticated in
            syncShellAuthentication(isAuthenticated)
            if !isAuthenticated {
                cancelInjectedAttachTask()
                startupConnectionCoordinator.reset()
            } else if !consumePendingURLIfReady() {
                reconnectStoredMacIfNeeded()
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
            if !isRestoringSession, !consumePendingURLIfReady() {
                reconnectStoredMacIfNeeded()
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        .onChange(of: store.connectionState) { _, connectionState in
            if connectionState == .connected {
                isShowingAddDeviceSheet = false
            } else {
                clearAttachTicketAuthenticationIfNeeded()
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            #endif
        }
        #if os(iOS)
        .onChange(of: authManager.currentUser?.id) { _, _ in
            // Account identity can in principle change without an
            // isAuthenticated or team edge; re-key the keep-alive so a stale
            // account's discovery loop is cancelled and restarted.
            updateOnboardingMacDiscoveryKeepAlive()
        }
        .onChange(of: onboardingStore.progress) { _, _ in
            updateOnboardingMacDiscoveryKeepAlive()
        }
        .onChange(of: store.isReconnectingStoredMac) { _, isReconnecting in
            if isReconnecting {
                isAwaitingOnboardingReconnectStart = false
            }
        }
        #endif
        .onChange(of: store.hasActiveUnexpiredAttachTicket) { _, hasActiveUnexpiredAttachTicket in
            if !hasActiveUnexpiredAttachTicket {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if shouldShowPushReadinessPreview {
            pushReadinessPreview
        } else if shouldShowChangesPreview {
            changesPreview
        } else if shouldShowHideComputersVerifier {
            hideComputersVerifier
        } else if shouldShowAgentChatDemoPreview {
            agentChatDemoPreview
        } else if shouldShowTerminalLayoutPreview {
            terminalLayoutPreview
        } else if shouldShowWorkspaceListLayoutPreview {
            workspaceListLayoutPreview
        } else if shouldShowHiddenComputersPreview {
            hiddenComputersPreview
        } else if shouldShowStreamingChatPreview {
            streamingChatPreview
        } else if shouldShowOnboardingPreview {
            onboardingPreview
        } else if shouldShowOnboarding {
            onboardingFlow
        } else if !isAuthenticated {
            SignInView()
        } else {
            switch MobileRootAuthGate.shellSurface(
                connectionState: store.connectionState,
                showRestoringStoredMac: shouldShowRestoringStoredMac,
                showDisconnectedNoPairedMacShell: MobileAuthenticatedShellPresentation.resolve(
                    connectionState: store.connectionState,
                    hasKnownPairedMac: store.hasKnownPairedMac,
                    hasHiddenComputers: store.hasHiddenComputers
                ) == .disconnected
            ) {
            case .disconnectedNoKnownPairedMac:
                // ONLY when there are no saved Macs at all: the add-device flow (it
                // auto-presents the pairing sheet since there is nothing to list).
                DisconnectedWorkspaceShellView(
                    hasKnownPairedMac: store.hasKnownPairedMac,
                    showAddDevice: showAddDevice,
                    showPairingScanner: showPairingScanner,
                    signOut: signOut,
                    setupHelpHighlight: disconnectedSetupHelpHighlight,
                    store: store
                )
            case .workspaceShell(let isRestoringStoredMac):
                // Restoring, connected, and offline-with-saved-Macs are ONE
                // mounted view whose inputs vary, so shell presentation state
                // (an open Settings sheet, navigation) survives the reconnect
                // window resolving. The integrated cross-Mac workspace list
                // renders whatever workspaces have aggregated (foreground +
                // live secondary subscriptions); the foreground connection is
                // established without any tap, and opening a workspace attaches
                // its Mac on demand.
                WorkspaceShellHost(
                    store: store,
                    isRestoringStoredMac: isRestoringStoredMac,
                    signOut: signOut,
                    showAddDevice: showAddDevice,
                    showPairingScanner: showPairingScanner,
                    reconnectStoredMac: reconnectStoredMacIfNeeded,
                    workspaceListDidBecomeVisible: {
                        await pushCoordinator.workspaceListDidBecomeVisible()
                    }
                )
            }
        }
    }

    private var addDeviceSheetBinding: Binding<Bool> {
        Binding(
            get: { isShowingAddDeviceSheet },
            set: { isPresented in
                if isPresented {
                    showAddDevice()
                } else {
                    dismissAddDeviceSheet()
                }
            }
        )
    }

    @ViewBuilder
    private var pairingSheet: some View {
        PairingView(
            pairingCode: $store.pairingCode,
            initialPresentation: pairingPresentation,
            connectionError: store.connectionError,
            connectionErrorGuidance: store.connectionErrorGuidance,
            versionWarning: store.pairingVersionWarning,
            connectPairingCode: {
                await store.connectPairingInput()
            },
            acceptVersionWarning: {
                let result = await store.acceptPairingVersionWarning()
                clearAttachTicketAuthentication(after: result)
                if result == .connected {
                    dismissAddDeviceSheet()
                }
            },
            connectManualHost: { name, host, port in
                await store.connectManualHost(name: name, host: host, port: port)
            },
            cancelPairing: cancelPairing,
            cancel: dismissAddDeviceSheet
        )
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $addDeviceSheetDetent)
        .presentationDragIndicator(.visible)
        #endif
    }

    /// Which setup gate the disconnected screen's "Trouble connecting?" help marks
    /// as the user's current step. When the host rejected this device on
    /// authorization grounds (a different cmux account, or a token it could not
    /// verify), the account gate wins, since retrying cannot fix it. Otherwise a
    /// returning device whose stored Mac just failed to reconnect has a known
    /// paired Mac, so its recovery path is "wake the Mac"; a device that has never
    /// paired is guided to install and pair. `connectionRequiresReauth` is the
    /// store's existing public signal for that auth rejection; this only reads it.
    private var disconnectedSetupHelpHighlight: MobileSetupGuidanceState {
        MobileSetupGuidancePolicy.state(
            isSignedIn: isAuthenticated,
            hasKnownPairedMac: store.hasKnownPairedMac,
            hasAccountMismatch: store.connectionRequiresReauth
        )
    }

    /// Whether first-run onboarding has an unfinished durable milestone.
    private var shouldShowOnboarding: Bool {
        #if os(iOS)
        return onboardingStore.progress.shouldShowOnboarding
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func updateOnboardingMacDiscoveryKeepAlive() {
        let isDiscoveryAuthorized = authManager.isAuthenticated
            && !authManager.isRestoringSession
            && !hasActiveAttachTicketAuthentication
        // The loop re-reads this before every attempt and re-arm, so a dropped
        // SwiftUI onChange push can never leave it searching after the connect
        // page took over, the Mac connected, or onboarding finished. Capture the
        // stores (app-lifetime objects), never the view struct: environment
        // values like `scenePhase` are only valid during body evaluation, so
        // scene-phase gating stays in the pushed `shouldKeepSearching` below.
        let isStillEligible: @MainActor () -> Bool = { [store, onboardingStore] in
            onboardingStore.progress == .welcome
                && store.connectionState != .connected
        }
        onboardingMacDiscoveryKeepAlive.update(
            isDiscoveryAuthorized: isDiscoveryAuthorized,
            accountKey: OnboardingDiscoveryAccountKey(
                userID: authManager.currentUser?.id,
                teamID: authManager.resolvedTeamID
            ),
            shouldKeepSearching: isStillEligible()
                && scenePhase == .active
                && !hasInjectedAttachLaunchRoute,
            isStillEligible: isStillEligible,
            coordinator: startupConnectionCoordinator,
            runAttempt: { [store, authManager] in
                await store.reconnectActiveMacIfAvailable(
                    stackUserID: authManager.currentUser?.id
                )
            }
        )
    }
    #endif

    @ViewBuilder
    private var onboardingFlow: some View {
        #if os(iOS)
        OnboardingFlowView(
            initialStage: initialOnboardingStage,
            context: .firstRun,
            isAuthenticated: isAuthenticated,
            connectionPhase: onboardingConnectionPhase,
            connectionMethod: connectionMethodStore?.method ?? .automatic,
            onSelectConnectionMethod: { connectionMethodStore?.method = $0 },
            onReachedConnection: markOnboardingReadyToConnect,
            onSkip: completeOnboarding,
            onRetryConnection: retryAutomaticConnection,
            onStartFallbackPairing: showOnboardingPairingScanner,
            onComplete: completeOnboarding
        )
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private var onboardingPreview: some View {
        #if os(iOS) && DEBUG
        OnboardingFlowView(
            initialStage: initialOnboardingStage,
            context: .preview,
            isAuthenticated: true,
            connectionPhase: UITestConfig.onboardingConnectionFallbackEnabled
                ? .fallback
                : .searching,
            connectionMethod: connectionMethodStore?.method ?? .automatic,
            onSelectConnectionMethod: { connectionMethodStore?.method = $0 },
            onReachedConnection: markOnboardingReadyToConnect,
            onSkip: completeOnboarding,
            onRetryConnection: {},
            onStartFallbackPairing: showOnboardingPairingScanner,
            onComplete: completeOnboarding
        )
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    private var initialOnboardingStage: OnboardingStage {
        onboardingStore.progress == .connect ? .connect : .agents
    }

    private var onboardingConnectionPhase: OnboardingConnectionPhase {
        OnboardingConnectionPhase(
            isMacReady: store.connectionState == .connected,
            isSearching: isAwaitingOnboardingReconnectStart || store.isReconnectingStoredMac,
            didFinishSearch: store.didFinishStoredMacReconnectAttempt
        )
    }

    private func markOnboardingReadyToConnect() {
        onboardingStore.markReadyToConnect()
        guard isAuthenticated, store.connectionState != .connected else { return }
        let stackUserID = authManager.currentUser?.id
        isAwaitingOnboardingReconnectStart = true
        Task {
            defer { isAwaitingOnboardingReconnectStart = false }
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
        }
    }

    private func completeOnboarding() {
        onboardingStore.markComplete()
    }
    #endif

    private var isAuthenticated: Bool {
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication
        )
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

    private var hasActiveAttachTicketAuthentication: Bool {
        didAuthenticateWithAttachTicket && store.hasActiveUnexpiredAttachTicket
    }

    private func syncShellAuthentication(
        _ isAuthenticated: Bool,
        isRestoringSession: Bool? = nil
    ) {
        let isRestoringSession = isRestoringSession ?? authManager.isRestoringSession
        if !isAuthenticated, !isRestoringSession {
            // Automatic auth loss (session expiry/revalidation) signs the
            // shell out below, unmounting the connection presenter before it
            // can dismiss anything; clear like the manual sign-out path so no
            // actionable toast survives onto the sign-in screen. Mirrors the
            // gate's own signOut condition.
            toasts.dismissAll()
        }
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: isAuthenticated,
            isRestoringSession: isRestoringSession,
            store: store
        )
    }

    /// Starts the stored-Mac reconnect when authenticated, unless a UITest attach
    /// URL took over. Called from both initial `onAppear` (covers a mount that is
    /// already authenticated) and `onChange(of: isAuthenticated)` (covers a
    /// sign-in that completes after mount) so the restoring gate always resolves
    /// even when the auth state never transitions while this view is mounted.
    private func reconnectStoredMacIfNeeded() {
        guard isAuthenticated, !authManager.isRestoringSession else { return }
        let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
        guard !startedUITestAttachURL,
              MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                isRestoringSession: authManager.isRestoringSession,
                connectionState: store.connectionState
              ) else { return }
        guard let startupAttempt = startupConnectionCoordinator.claimStoredReconnect() else { return }
        let stackUserID = authManager.currentUser?.id
        didExceedStartupRestoringGate = false
        let restoringGateDeadline = Task { @MainActor in
            try? await ContinuousClock().sleep(
                for: .seconds(Self.startupRestoringGateSeconds)
            )
            guard !Task.isCancelled, store.connectionState != .connected else { return }
            didExceedStartupRestoringGate = true
        }
        Task {
            defer { restoringGateDeadline.cancel() }
            _ = await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            startupConnectionCoordinator.finishStoredReconnect(startupAttempt)
        }
    }

    /// A user retry intentionally supersedes any startup attempt that is still
    /// winding down after the restoring deadline exposed the fallback UI.
    private func retryAutomaticConnection() {
        let stackUserID = authManager.currentUser?.id
        Task {
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
        }
    }

    private func showAddDevice() {
        presentAddDevice(.manual)
    }

    private func showPairingScanner() {
        presentAddDevice(.scanner(entry: .settingsReplay))
    }

    private func showOnboardingPairingScanner() {
        presentAddDevice(.scanner(entry: .onboardingFallback))
    }

    private func presentAddDevice(_ presentation: PairingPresentation) {
        if isShowingAddDeviceSheet {
            guard pairingPresentation != presentation else { return }
            pairingPresentation = presentation
            return
        }
        pairingPresentation = presentation
        #if os(iOS)
        addDeviceSheetDetent = .large
        #endif
        isShowingAddDeviceSheet = true
    }

    private func connectAttachURL(_ rawURL: String) {
        guard !authManager.isRestoringSession else {
            pendingAttachURL = rawURL
            return
        }
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication(true)
        Task {
            let result = await store.connectPairingURLResult(rawURL)
            if result == .needsUserApproval {
                showAddDevice()
            }
            clearAttachTicketAuthentication(after: result)
            if result == .failed, store.connectionState != .connected {
                reconnectStoredMacIfNeeded()
            }
        }
    }

    @discardableResult
    private func consumePendingURLIfReady() -> Bool {
        guard let rawURL = pendingAttachURL else { return false }
        if isRawAttachURL(rawURL) {
            guard !authManager.isRestoringSession else { return false }
            pendingAttachURL = nil
            connectAttachURL(rawURL)
            return true
        }
        guard isAuthenticated else { return false }
        pendingAttachURL = nil
        Task {
            await store.connectPairingURL(rawURL)
            if store.connectionState != .connected {
                reconnectStoredMacIfNeeded()
            }
        }
        return true
    }

    private func isRawAttachURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        return MobileRootAuthGate.isAttachURL(url)
    }

    private func cancelPairing() {
        store.cancelPairing()
        clearAttachTicketAuthenticationIfNeeded()
    }

    private func dismissAddDeviceSheet() {
        isShowingAddDeviceSheet = false
        pairingPresentation = .manual
        if store.pairingVersionWarning != nil {
            cancelPairing()
        } else {
            clearAttachTicketAuthenticationIfNeeded()
        }
    }

    private func clearAttachTicketAuthentication(after result: MobilePairingURLConnectionResult) {
        guard MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: result,
            connectionState: store.connectionState,
            hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
        ) else { return }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication(authManager.isAuthenticated)
    }

    private func clearAttachTicketAuthenticationIfNeeded() {
        guard didAuthenticateWithAttachTicket,
              store.connectionState != .connected || !store.hasActiveUnexpiredAttachTicket else {
            return
        }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication(authManager.isAuthenticated)
    }

    private func signOut() {
        cancelInjectedAttachTask()
        Task {
            // Local shell teardown first so the whole UI lands signed out
            // immediately; authManager.signOut clears the local session up
            // front and only then runs its bounded best-effort server teardown
            // (push-token DELETE, Stack session revocation).
            didAuthenticateWithAttachTicket = false
            didExceedStartupRestoringGate = false
            startupConnectionCoordinator.reset()
            // Hard context switch: queued toasts must not outlive the
            // session. The connection presenter also suppresses its capsule
            // once isSignedIn flips, but that races the snapshot change
            // store.signOut() makes; this clears everything up front.
            toasts.dismissAll()
            store.signOut()
            let serverTeardown = signOutHook.begin()
            await authManager.signOut(onSignedOut: serverTeardown)
        }
    }

    @discardableResult
    private func connectUITestAttachURLIfNeeded() -> Bool {
        #if DEBUG
        // Auto-pair when an attach URL is supplied at launch. Two sources:
        //   - CMUX_DOGFOOD_ATTACH_URL (UITestConfig.dogfoodAttachURL): NOT gated on
        //     mock data, so it fires against the real backend. The dev-launch
        //     tooling (scripts/mobile-dev-launch.sh, scripts/dev-setup.sh) signs in
        //     for real (CMUX_UITEST_STACK_* with CMUX_UITEST_MOCK_DATA=0) and wants
        //     the phone to auto-pair to the freshly built Mac dev app. With mock
        //     off, UITestConfig.attachURL is always nil, so this dedicated accessor
        //     is what un-breaks real-backend auto-pair.
        //   - CMUX_UITEST_ATTACH_URL (UITestConfig.attachURL): gated on mock data,
        //     kept intact for the XCUITest harness.
        // No-op unless one of those env vars is set, so normal launches are
        // unaffected.
        guard isAuthenticated,
              let attachURL = UITestConfig.dogfoodAttachURL ?? UITestConfig.attachURL else {
            return false
        }
        if startupConnectionCoordinator.shouldFallBackFromInjectedAttach {
            return false
        }
        guard let startupAttempt = startupConnectionCoordinator.claimInjectedAttach() else {
            return true
        }
        injectedAttachTaskAttempt = startupAttempt
        injectedAttachTask = Task { @MainActor in
            let completion = await dogfoodAttachPreparation.run {
                await startupConnectionCoordinator.connectInjectedAttach(
                    startupAttempt,
                    attachURL: attachURL
                ) { rawURL in
                    await store.connectPairingURLResult(rawURL)
                }
            }
            guard !Task.isCancelled,
                  injectedAttachTaskAttempt == startupAttempt,
                  let completion else {
                return
            }
            if completion.result == .needsUserApproval {
                showAddDevice()
            }
            clearInjectedAttachTask(ifCurrent: startupAttempt)
            if completion.shouldReconnectStoredMac {
                reconnectStoredMacIfNeeded()
            }
        }
        return true
        #else
        return false
        #endif
    }

    private func cancelInjectedAttachTask(retryLaunchRoute: Bool = false) {
        guard let attempt = injectedAttachTaskAttempt else { return }
        let task = injectedAttachTask
        injectedAttachTask = nil
        injectedAttachTaskAttempt = nil
        _ = startupConnectionCoordinator.cancelInjectedAttach(
            attempt,
            retryLaunchRoute: retryLaunchRoute
        )
        task?.cancel()
    }

    private func clearInjectedAttachTask(
        ifCurrent attempt: MobileStartupConnectionCoordinator.Attempt
    ) {
        guard injectedAttachTaskAttempt == attempt else { return }
        injectedAttachTask = nil
        injectedAttachTaskAttempt = nil
    }
}

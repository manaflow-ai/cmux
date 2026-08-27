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
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog
    /// Optional so previews and hosts without the app root still render.
    @Environment(MobileConnectionMethodStore.self) private var connectionMethodStore:
        MobileConnectionMethodStore?
    /// Optional environment models do not reliably invalidate this root when a
    /// child sheet mutates them. Mirror the store's existing change stream so
    /// capability closures are rebuilt for the newly selected method.
    @State private var connectionMethodObservationToken: MobileConnectionMethod?
    @Environment(\.dogfoodAttachPreparation) private var dogfoodAttachPreparation
    private let signOutHook: MobileSignOutHook
    private let startupConnectionCoordinator: MobileStartupConnectionCoordinator
    #if os(iOS)
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    /// Optional so previews and package hosts remain migration-free by default.
    @Environment(MobileAutoConnectMigrationStore.self) private var autoConnectMigrationStore:
        MobileAutoConnectMigrationStore?
    /// Persists the last durable milestone in first-run onboarding.
    @Bindable private var onboardingStore: MobileOnboardingStore
    @State private var isAwaitingOnboardingReconnectStart = false
    @State private var onboardingMacDiscoveryKeepAlive = OnboardingMacDiscoveryKeepAlive()
    /// The shared iOS modal slot for root sheets and shell-owned child sheets.
    @State private var rootPresentation: MobileRootPresentationState
    #if DEBUG
    /// One-shot latch for the UI-test auto-open-first-workspace hook.
    @State private var didAutoOpenFirstWorkspaceForUITest = false
    #endif
    #endif
    @State private var pendingAttachURL: String?
    @State private var didAuthenticateWithAttachTicket = false
    /// Prevents the initial authenticated publication from dialing before the
    /// auth coordinator finishes loading the account's effective team. That
    /// first team transition invalidates attempts created in the teamless
    /// scope, so connection startup belongs after this barrier.
    @State private var didFinishAuthBootstrap = false
    @State private var didExceedStartupRestoringGate = false
    /// One owner for the setup requirement's loading and required phases.
    /// Durable readiness remains in the shell store.
    @State private var tailscaleSetupPrompt = MobileTailscaleSetupPromptState()
    #if os(macOS)
    @State private var isShowingAddDeviceSheet = false
    @State private var pairingPresentation: PairingPresentation = .manual
    #endif
    @State private var openURLTask: Task<Void, Never>?
    @State private var openURLTaskToken: UUID?
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
        var initialRootPresentation = MobileRootPresentationState()
        #if DEBUG
        let migrationFixture = AutoConnectMigrationUITestConfiguration.currentProcess
        if migrationFixture?.presentsShellSettingsBeforeMigration == true {
            initialRootPresentation.apply(.presentSettings)
        } else {
            switch migrationFixture?.initialModalHost {
            case .rootPairing:
                initialRootPresentation.apply(.presentPairing(.manual))
            case .workspaceListDeviceTree:
                initialRootPresentation.apply(.presentChild(.workspaceList(.deviceTree)))
            case .workspaceDetailTerminalText:
                initialRootPresentation.apply(.presentChild(.workspaceDetail(.terminalText)))
            case nil:
                break
            }
        }
        #endif
        _rootPresentation = State(initialValue: initialRootPresentation)
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

    private var shouldShowMacSurfaceGalleryPreview: Bool {
        #if os(iOS) && DEBUG
        return UITestConfig.macSurfaceGalleryPreviewPage != nil
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

    @ViewBuilder private var macSurfaceGalleryPreview: some View {
        #if os(iOS) && DEBUG
        MacSurfaceGalleryPreviewView()
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
        #if os(iOS)
        .environment(
            \.mobileChildPresentationProvider,
            MobileChildPresentationProvider(resolve: childSheetPresentation)
        )
        .sheet(
            isPresented: rootPresentationBinding,
            onDismiss: rootPresentationDidDismiss
        ) {
            rootPresentationContent
                .interactiveDismissDisabled(shouldHoldRootSettingsForMigration)
        }
        #else
        .sheet(isPresented: addDeviceSheetBinding) {
            pairingSheet(initialPresentation: pairingPresentation)
        }
        #endif
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
            presentAutoConnectMigrationIfEligible()
            #endif
        }
        .task(id: connectionMethodStore.map(ObjectIdentifier.init)) {
            guard let connectionMethodStore else {
                connectionMethodObservationToken = nil
                return
            }
            for await method in connectionMethodStore.changes() {
                connectionMethodObservationToken = method
            }
        }
        .task {
            // Auth launch restore can publish `isAuthenticated` and finish
            // `isRestoringSession` in one main-actor turn. SwiftUI is allowed
            // to coalesce those observations, which would skip the one-shot
            // attach callback for a tagged Iroh launch. Awaiting the
            // coordinator's bootstrap gives startup a durable completion
            // barrier; the coordinator still serializes this with the normal
            // lifecycle callbacks, so it cannot start a duplicate dial.
            await finishAuthenticationBootstrapAndConnect()
        }
        .onChange(of: store.tailscaleSetupStatus, initial: true) { _, status in
            tailscaleSetupPrompt.apply(.shellStatusChanged(status))
        }
        .onDisappear {
            cancelOpenURLTask(failure: .cancelled)
            clearAttachTicketAuthenticationIfNeeded()
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
        #if DEBUG
        // The UI-test auto-open hook observes the same workspace-arrival
        // signal; `initial: true` covers a list already loaded at mount.
        .onChange(of: store.workspaceTopologyVersion, initial: true) { _, _ in
            autoOpenFirstWorkspaceForUITestIfNeeded()
        }
        #endif
        #endif
        .onChange(of: authManager.resolvedTeamID) { _, _ in
            diagnosticLog?.recordAppEvent(.authTeamChanged)
            // Ignore pre-bootstrap publications; the durable bootstrap task
            // applies the final account/team scope before it permits a dial.
            // A delayed callback for that same scope is coalesced by the
            // app-lifetime startup coordinator.
            accountScopeDidChangeAfterBootstrap()
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            presentAutoConnectMigrationIfEligible()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.resumeForegroundRefresh()
                // The user may have toggled Tailscale while we were backgrounded.
                tailscaleStatusMonitor?.refresh()
                // Auth resume belongs to the process-owned Iroh composition,
                // which distinguishes real background returns from system UI.
            case .background:
                store.suspendForegroundRefresh()
            case .inactive:
                // Control Center, system prompts, and foreground handoffs can
                // make the scene inactive without suspending the process. Keep
                // the current transport recovery owner alive through that edge.
                break
            @unknown default:
                break
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            presentAutoConnectMigrationIfEligible()
            #endif
        }
        .onChange(of: tailscaleStatusMonitor?.status, initial: true) { _, status in
            let value: Int = switch status {
            case .some(.active):
                1
            case .some(.inactiveOrNotInstalled):
                0
            case .some(.unknown), .none:
                2
            }
            diagnosticLog?.recordAppEvent(.tailscaleStatusChanged, count: value)
        }
        .onOpenURL { url in
            let rawURL = url.absoluteString
            diagnosticLog?.recordAppEvent(.appOpenURLReceived)
            if MobileRootAuthGate.isAttachURL(url) {
                connectAttachURL(rawURL)
                return
            }

            guard isAuthenticated else {
                pendingAttachURL = rawURL
                diagnosticLog?.recordAppEvent(.appOpenURLDeferredForAuthentication)
                return
            }
            startOpenURLConnection(rawURL)
        }
        .onChange(of: isAuthenticated) { _, isAuthenticated in
            syncShellAuthentication(isAuthenticated)
            if !isAuthenticated {
                didFinishAuthBootstrap = false
                startupConnectionCoordinator.reset()
            } else {
                Task { await finishAuthenticationBootstrapAndConnect() }
            }
            #if os(iOS)
            handleRootPresentation(
                .authenticationChanged(isAuthenticated: isAuthenticated)
            )
            updateOnboardingMacDiscoveryKeepAlive()
            presentAutoConnectMigrationIfEligible()
            #if DEBUG
            // Auth can resolve after the workspace list is already loaded, so
            // the topology-version hook alone would miss the arm-late case.
            autoOpenFirstWorkspaceForUITestIfNeeded()
            #endif
            #endif
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
            if !isRestoringSession, !consumePendingURLIfReady() {
                reconnectStoredMacIfNeeded()
            }
            #if os(iOS)
            updateOnboardingMacDiscoveryKeepAlive()
            presentAutoConnectMigrationIfEligible()
            #endif
        }
        .onChange(of: store.connectionState) { _, connectionState in
            if connectionState == .connected {
                #if os(iOS)
                handleRootPresentation(.dismissPairing)
                #else
                isShowingAddDeviceSheet = false
                #endif
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
            accountScopeDidChangeAfterBootstrap()
            updateOnboardingMacDiscoveryKeepAlive()
        }
        .onChange(of: onboardingStore.progress) { _, progress in
            handleRootPresentation(
                .migrationEligibilityChanged(isEligible: progress == .complete)
            )
            updateOnboardingMacDiscoveryKeepAlive()
            presentAutoConnectMigrationIfEligible()
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
        } else if shouldShowTerminalLayoutPreview {
            terminalLayoutPreview
        } else if shouldShowWorkspaceListLayoutPreview {
            workspaceListLayoutPreview
        } else if shouldShowMacSurfaceGalleryPreview {
            macSurfaceGalleryPreview
        } else if shouldShowHiddenComputersPreview {
            hiddenComputersPreview
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
                    showAddDevice: addComputerAction,
                    showPairingScanner: pairingScannerAction,
                    signOut: signOut,
                    setupHelpHighlight: disconnectedSetupHelpHighlight,
                    store: store,
                    tailscalePairingRequired: tailscaleSetupPrompt.requiresPairing,
                    showSettings: showSettings,
                    showComputers: showComputers,
                    setupHelpPresentation: childSheetPresentation(
                        for: .disconnectedSetupHelp
                    )
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
                    showAddDevice: addComputerAction,
                    showPairingScanner: pairingScannerAction,
                    tailscalePairingRequired: tailscaleSetupPrompt.requiresPairing,
                    showSettings: showSettings,
                    showComputers: showComputers,
                    taskComposerPresentation: childSheetPresentation(
                        for: .workspaceTaskComposer
                    ),
                    reconnectStoredMac: reconnectStoredMacIfNeeded,
                    workspaceListDidBecomeVisible: {
                        await pushCoordinator.workspaceListDidBecomeVisible()
                    }
                )
            }
        }
    }

    #if os(macOS)
    /// Preserves the existing macOS pairing presenter independently of iOS routing.
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
    #endif

    /// Builds the shared pairing flow for either platform's root presenter.
    private func pairingSheet(initialPresentation: PairingPresentation) -> some View {
        PairingView(
            pairingCode: $store.pairingCode,
            initialPresentation: initialPresentation,
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

    #if os(iOS)
    /// Drives one stable sheet host from the root presentation state.
    private var rootPresentationBinding: Binding<Bool> {
        Binding(
            get: { rootPresentation.isRootSheetPresented },
            set: { isPresented in
                guard !isPresented else { return }
                handleRootPresentation(.sheetDidRequestDismissal)
            }
        )
    }

    /// Resolves the current enum case inside the one root sheet host.
    @ViewBuilder
    private var rootPresentationContent: some View {
        switch rootPresentation.presentation {
        case .autoConnectMigrationIntroduction:
            MobileAutoConnectMigrationSheet(
                useAutoConnect: {
                    handleRootPresentation(.useAutoConnect)
                },
                setUpTailscale: {
                    handleRootPresentation(.setUpTailscale(
                        status: store.tailscaleSetupStatusWhenSelected
                    ))
                },
                showsLayoutProbe: showsAutoConnectMigrationLayoutProbe
            )
        case .settings:
            settingsSheet(initialFocus: nil)
        case .computers:
            DeviceTreeView(
                store: store,
                selectWorkspace: selectWorkspaceFromComputers,
                showAddDevice: addComputerAction,
                dismissAction: dismissComputers
            )
        case let .pairing(pairingPresentation):
            pairingSheet(initialPresentation: pairingPresentation)
        case .child, .dismissingChild, nil:
            EmptyView()
        }
    }

    /// Keeps the automation-only viewport leaf absent from normal app launches.
    private var showsAutoConnectMigrationLayoutProbe: Bool {
        #if DEBUG
        AutoConnectMigrationUITestConfiguration.currentProcess?.showsLayoutProbe == true
        #else
        false
        #endif
    }

    /// The one root-hosted Settings page used by either shell and the migration route.
    private func settingsSheet(initialFocus: MobileSettingsFocus?) -> some View {
        MobileSettingsView(
            connectedHostName: store.connectedHostName,
            startPairingScanner: pairingScannerAction,
            signOut: signOut,
            store: store,
            initialFocus: initialFocus,
            dismissAction: dismissRootSettings
        )
    }

    /// Keeps the root modal session alive while advancing queued migration content.
    private var shouldHoldRootSettingsForMigration: Bool {
        rootPresentation.presentation == .settings
            && isAutoConnectMigrationReady
    }

    /// Settings and the queued migration share one host, so no dismissal race exists.
    private func dismissRootSettings() {
        handleRootPresentation(
            .dismissSettings(presentAutoConnectMigration: isAutoConnectMigrationReady)
        )
    }

    /// Requests root Settings without depending on the currently mounted shell.
    private func showSettings() {
        handleRootPresentation(.presentSettings)
    }

    /// The Computers screen and the root routes it can open share this one
    /// presenter, so changing the underlying authenticated shell cannot orphan
    /// modal ownership.
    private func showComputers() {
        handleRootPresentation(.presentComputers)
    }

    private func dismissComputers() {
        handleRootPresentation(.dismissComputers)
    }

    private func selectWorkspaceFromComputers(_ id: MobileWorkspacePreview.ID) {
        store.selectedWorkspaceID = id
        dismissComputers()
    }

    /// Presents only after the authenticated shell owns the screen and no
    /// higher-priority pairing or explicit-attach flow owns a modal slot.
    private func presentAutoConnectMigrationIfEligible() {
        guard isAutoConnectMigrationReady,
              rootPresentation.isIdle else {
            return
        }
        handleRootPresentation(.presentAutoConnectMigrationIfIdle)
    }

    /// All migration gates except ownership of the shared modal slot.
    private var isAutoConnectMigrationReady: Bool {
        var isRestoringAuthentication = authManager.isRestoringSession
        var isSceneActive = scenePhase == .active
        var hasExplicitAttachRoute = hasInjectedAttachLaunchRoute
        #if DEBUG
        switch AutoConnectMigrationUITestConfiguration.currentProcess?.readinessGate {
        case .authenticationRestoring:
            isRestoringAuthentication = true
        case .sceneInactive:
            isSceneActive = false
        case .explicitAttachRoute:
            hasExplicitAttachRoute = true
        case nil:
            break
        }
        #endif
        return MobileAutoConnectMigrationReadiness(
            hasPendingMigration: autoConnectMigrationStore?.resolution == .pending,
            hasCompletedOnboarding: onboardingStore.progress == .complete,
            isAuthenticated: authManager.isAuthenticated,
            isRestoringAuthentication: isRestoringAuthentication,
            isSceneActive: isSceneActive,
            hasExplicitAttachRoute: hasExplicitAttachRoute
        ).canPresent
    }

    /// Applies one root presentation action and performs its domain side effect.
    private func handleRootPresentation(_ action: MobileRootPresentationState.Action) {
        let previousPresentation = rootPresentation.presentation
        let effect = rootPresentation.apply(action)
        if previousPresentation != rootPresentation.presentation {
            switch action {
            case .presentAutoConnectMigrationIfIdle:
                diagnosticLog?.recordAppEvent(.autoConnectMigrationPresented)
            case .useAutoConnect:
                diagnosticLog?.recordAppEvent(.autoConnectMigrationAccepted)
            case .setUpTailscale:
                diagnosticLog?.recordAppEvent(.autoConnectMigrationDismissed)
            case .sheetDidRequestDismissal
                where previousPresentation == .autoConnectMigrationIntroduction:
                diagnosticLog?.recordAppEvent(.autoConnectMigrationDismissed)
            default:
                break
            }
        }
        switch effect {
        case .none:
            break
        case .acknowledgeAutoConnectMigration:
            autoConnectMigrationStore?.acknowledge()
        case .useAutoConnect:
            connectionMethodStore?.method = .automatic
            autoConnectMigrationStore?.acknowledge()
        case let .setUpTailscale(requiresPairing):
            connectionMethodStore?.method = .tailscale
            tailscaleSetupPrompt.apply(
                .selectedTailscale(requiresPairing: requiresPairing)
            )
            autoConnectMigrationStore?.acknowledge()
        case .finishPairing:
            finishPairingPresentation()
        case .retryAutoConnectMigration:
            presentAutoConnectMigrationIfEligible()
        }
    }

    /// Re-evaluates a pending migration after the one root sheet leaves screen.
    private func rootPresentationDidDismiss() {
        presentAutoConnectMigrationIfEligible()
    }
    #endif

    /// Connects one child sheet to the root-owned iOS modal state machine.
    private func childSheetPresentation(
        for child: MobileRootPresentationState.ChildPresentation
    ) -> MobileChildSheetPresentation {
        #if os(iOS)
        return MobileChildSheetPresentation(
            isPresented: Binding(
                get: { rootPresentation.isPresentingChild(child) },
                set: { isPresented in
                    handleRootPresentation(
                        isPresented ? .presentChild(child) : .dismissChild(child)
                    )
                }
            ),
            didDismiss: {
                handleRootPresentation(.childDidDismiss(child))
            }
        )
        #else
        return MobileChildSheetPresentation()
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
            onEnablePush: { await pushCoordinator.enable(trigger: "onboarding") },
            onReachedConnection: markOnboardingReadyToConnect,
            onSkip: completeOnboarding,
            onRetryConnection: retryAutomaticConnection,
            onStartTailscalePairing: showOnboardingPairingScanner,
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
            // The deterministic preview must never raise the OS alert.
            onEnablePush: { true },
            onReachedConnection: markOnboardingReadyToConnect,
            onSkip: completeOnboarding,
            onRetryConnection: {},
            onStartTailscalePairing: showOnboardingPairingScanner,
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

    #if DEBUG
    /// Auto-opens the first loaded workspace once for the headless UI-test
    /// harness (`CMUX_UITEST_AUTO_OPEN_FIRST_WORKSPACE=1`), so scripted
    /// terminal verification (e.g. the scroll script) reaches a workspace
    /// detail without GUI taps. Called only from onChange handlers. DEBUG-only.
    private func autoOpenFirstWorkspaceForUITestIfNeeded() {
        guard UITestConfig.autoOpenFirstWorkspaceEnabled,
              !didAutoOpenFirstWorkspaceForUITest,
              isAuthenticated,
              let firstWorkspaceID = store.workspaces.first?.id else { return }
        didAutoOpenFirstWorkspaceForUITest = true
        store.navigateToWorkspaceForDeeplink(firstWorkspaceID)
    }
    #endif
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
        guard isAuthenticated,
              didFinishAuthBootstrap,
              !authManager.isRestoringSession else { return }
        let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
        guard !startedUITestAttachURL,
              MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                didFinishAuthBootstrap: didFinishAuthBootstrap,
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

    /// Establishes the account boundary before any startup transport attempt.
    /// The app-lifetime coordinator makes duplicate SwiftUI delivery harmless.
    private func prepareResolvedAccountScope() -> Bool? {
        startupConnectionCoordinator.prepareAccountScope(
            userID: authManager.currentUser?.id,
            teamID: authManager.resolvedTeamID
        ) {
            store.currentTeamDidChange()
        }
    }

    private func finishAuthenticationBootstrapAndConnect() async {
        await authManager.awaitBootstrapped()
        guard !Task.isCancelled else { return }
        if authManager.isAuthenticated {
            guard prepareResolvedAccountScope() != nil else { return }
        }
        didFinishAuthBootstrap = true
        if !consumePendingURLIfReady() {
            reconnectStoredMacIfNeeded()
        }
    }

    private func accountScopeDidChangeAfterBootstrap() {
        guard didFinishAuthBootstrap,
              prepareResolvedAccountScope() == true,
              store.connectionState != .connected else { return }
        reconnectStoredMacIfNeeded()
    }

    /// A user retry intentionally supersedes any startup attempt that is still
    /// winding down after the restoring deadline exposed the fallback UI.
    private func retryAutomaticConnection() {
        let stackUserID = authManager.currentUser?.id
        Task {
            _ = await store.retryActiveMacReconnect(stackUserID: stackUserID)
        }
    }

    /// No method gate: `addComputerAction` renders this entrypoint everywhere,
    /// so a runtime re-check here would turn visible Add Computer buttons into
    /// silent no-ops on Iroh-only setups (the Computers sheet would dismiss
    /// with nothing after it). Only the scanner entrypoints below re-check.
    private func showAddDevice() {
        presentPairing(.manual)
    }

    private func showPairingScanner() {
        guard currentlyAllowsManualPairing else { return }
        presentPairing(.scanner(entry: .settingsReplay))
    }

    private func showOnboardingPairingScanner() {
        guard currentlyAllowsManualPairing else { return }
        presentPairing(.scanner(entry: .onboardingFallback))
    }

    /// An external attach ticket can require compatibility approval under any
    /// connection method. Its presentation contains no manual pairing controls.
    private func showAttachVersionApproval() {
        presentPairing(.versionApproval)
    }

    /// Add Computer (including its manual host:port form) is always available:
    /// entering the address where a same-account Mac is reachable IS discovery
    /// for LAN, WireGuard, and other networks Iroh may not find fast enough.
    /// Only the Tailscale pairing-code scanner keeps a method gate.
    private var addComputerAction: (() -> Void)? {
        showAddDevice
    }

    /// Scanner entrypoints use the same gate as the manual pairing form.
    private var pairingScannerAction: (() -> Void)? {
        guard allowsManualPairing else { return nil }
        return showPairingScanner
    }


    private var allowsManualPairing: Bool {
        #if os(iOS)
        // The stream value is only an invalidation token. Read the authoritative
        // store synchronously so the migration transition can expose pairing in
        // the same render that selects Tailscale. Tailscale is "selected"
        // wherever it applies: the app default OR any Computer's own method
        // (`tailscaleSetupStatus` covers both).
        _ = connectionMethodObservationToken
        return store.tailscaleSetupStatus != .notSelected
        #else
        return true
        #endif
    }

    /// Re-check the source of truth when an already-rendered action fires. This
    /// closes the brief transition where the observation task has not consumed
    /// a newly selected method yet.
    private var currentlyAllowsManualPairing: Bool {
        #if os(iOS)
        store.tailscaleSetupStatus != .notSelected
        #else
        true
        #endif
    }

    /// Routes pairing and attach approval through the platform's root presenter.
    private func presentPairing(_ presentation: PairingPresentation) {
        #if os(iOS)
        addDeviceSheetDetent = .large
        handleRootPresentation(.presentPairing(presentation))
        #else
        if isShowingAddDeviceSheet {
            guard pairingPresentation != presentation else { return }
            pairingPresentation = presentation
            return
        }
        pairingPresentation = presentation
        isShowingAddDeviceSheet = true
        #endif
    }

    private func connectAttachURL(_ rawURL: String) {
        guard !authManager.isRestoringSession else {
            pendingAttachURL = rawURL
            diagnosticLog?.recordAppEvent(.appOpenURLDeferredForAuthentication)
            return
        }
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication(true)
        startOpenURLConnection(
            rawURL,
            followUp: .finishAttachTicketAuthentication
        )
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
        startOpenURLConnection(rawURL, followUp: .reconnectIfDisconnected)
        return true
    }

    private func isRawAttachURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        return MobileRootAuthGate.isAttachURL(url)
    }

    private func startOpenURLConnection(
        _ rawURL: String,
        followUp: OpenURLConnectionFollowUp = .none
    ) {
        cancelOpenURLTask(failure: .superseded)
        let token = UUID()
        openURLTaskToken = token
        openURLTask = Task { @MainActor in
            let result = await store.connectPairingURLResult(rawURL)
            guard !Task.isCancelled, openURLTaskToken == token else { return }
            let failure: DiagnosticFailureKind? = switch result {
            case .connected:
                nil
            case .failed:
                .connectionClosed
            case .needsUserApproval:
                .policyUnavailable
            case .superseded:
                .superseded
            }
            diagnosticLog?.recordAppEvent(
                result.didConnect ? .appOpenURLHandled : .appOpenURLRejected,
                failure: failure
            )
            switch followUp {
            case .none:
                break
            case .finishAttachTicketAuthentication:
                if result == .needsUserApproval {
                    showAttachVersionApproval()
                }
                clearAttachTicketAuthentication(after: result)
                if result == .failed, store.connectionState != .connected {
                    reconnectStoredMacIfNeeded()
                }
            case .reconnectIfDisconnected:
                if store.connectionState != .connected {
                    reconnectStoredMacIfNeeded()
                }
            }
            guard openURLTaskToken == token else { return }
            openURLTask = nil
            openURLTaskToken = nil
        }
    }

    /// Follow-up owned by the stored open-URL task after its connection result.
    private enum OpenURLConnectionFollowUp {
        case none
        case finishAttachTicketAuthentication
        case reconnectIfDisconnected
    }

    private func cancelOpenURLTask(failure: DiagnosticFailureKind) {
        guard openURLTask != nil else { return }
        diagnosticLog?.recordAppEvent(.appOpenURLRejected, failure: failure)
        openURLTaskToken = nil
        openURLTask?.cancel()
        openURLTask = nil
    }

    private func cancelPairing() {
        store.cancelPairing()
        clearAttachTicketAuthenticationIfNeeded()
    }

    /// Dismisses pairing only when pairing owns the root presentation.
    private func dismissAddDeviceSheet() {
        #if os(iOS)
        handleRootPresentation(.dismissPairing)
        #else
        isShowingAddDeviceSheet = false
        pairingPresentation = .manual
        finishPairingPresentation()
        #endif
    }

    /// Clears pairing-only warning and attach-ticket state after dismissal.
    private func finishPairingPresentation() {
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
        diagnosticLog?.recordAppEvent(.authSignOutStarted)
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
            diagnosticLog?.recordAppEvent(
                authManager.isAuthenticated ? .authSignOutFailed : .authSignOutSucceeded,
                failure: authManager.isAuthenticated ? .protocolViolation : nil
            )
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
        return startupConnectionCoordinator.startInjectedAttach(
            attachURL: attachURL,
            prepare: {
                await dogfoodAttachPreparation.waitUntilReady()
            },
            connect: { rawURL in
                await store.connectPairingURLResult(rawURL)
            },
            onCompletion: { completion in
                if completion.result == .needsUserApproval {
                    showAttachVersionApproval()
                }
                if completion.shouldReconnectStoredMac {
                    reconnectStoredMacIfNeeded()
                }
            }
        )
        #else
        return false
        #endif
    }
}

import Foundation
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
import os
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

private let mobileRootViewLog = Logger(subsystem: "dev.cmux.ios", category: "mobile-root-view")

struct CMUXMobileRootView: View {
    private static let authenticatedUserScopeWaitTimeout: Duration = .seconds(8)

    @Bindable var store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthCoordinator.self) private var authManager
    #if os(iOS)
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    private let onboardingStore: MobileOnboardingStore
    @State private var hasSeenOnboarding: Bool
    #endif
    @State private var pendingAttachURL: String?
    @State private var didConsumeUITestAttachURL = false
    @State private var didAuthenticateWithAttachTicket = false
    @State private var isConnectingLaunchAttachURL = false
    @State private var isShowingAddDeviceSheet = false
    @State private var didTimeoutAuthenticatedUserScopeWait = false
    @State private var authenticatedUserScopeRetryGeneration = 0
    #if os(iOS)
    @State private var addDeviceSheetDetent: PresentationDetent = .large
    #endif
    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor

    #if os(iOS)
    init(store: CMUXMobileShellStore, onboardingStore: MobileOnboardingStore) {
        self.store = store
        self.onboardingStore = onboardingStore
        _hasSeenOnboarding = State(initialValue: onboardingStore.hasSeenOnboarding)
    }
    #else
    init(store: CMUXMobileShellStore) {
        self.store = store
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
            reconnectStoredMacIfNeeded()
        }
        #if os(iOS)
        .onChange(of: store.workspaceTopologyVersion) { _, _ in
            pushCoordinator.workspacesDidChange()
        }
        #endif
        .onChange(of: authManager.selectedTeamID) { _, _ in
            store.currentTeamDidChange()
            reconnectStoredMacIfNeeded()
        }
        .onChange(of: authManager.currentUser?.id) { _, _ in
            reconnectStoredMacIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.resumeForegroundRefresh()
            tailscaleStatusMonitor?.refresh()
            Task { await authManager.revalidateSession() }
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
            guard isAuthenticated else {
                return
            }
            if consumePendingURLIfReady() {
                return
            }
            reconnectStoredMacIfNeeded()
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
            guard !isRestoringSession else { return }
            _ = consumePendingURLIfReady()
        }
        .task(id: authenticatedUserScopeDeadlineTaskID) {
            await updateAuthenticatedUserScopeDeadline()
        }
        .onChange(of: store.connectionState) { _, connectionState in
            if connectionState == .connected {
                isShowingAddDeviceSheet = false
            } else {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
        .onChange(of: store.hasActiveUnexpiredAttachTicket) { _, hasActiveUnexpiredAttachTicket in
            if !hasActiveUnexpiredAttachTicket {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if shouldShowTerminalLayoutPreview {
            terminalLayoutPreview
        } else if shouldShowWorkspaceListLayoutPreview {
            workspaceListLayoutPreview
        } else if !isAuthenticated {
            SignInView()
        } else if didTimeoutAuthenticatedUserScopeWait {
            AuthenticatedUserScopeUnavailableView(
                retry: retryAuthenticatedUserScope,
                signOut: signOut
            )
        } else if shouldWaitForAuthenticatedUserScope {
            MobilePairedMacDeterminingView()
        } else if store.connectionState != .connected && shouldShowRestoringStoredMac {
            RestoringStoredMacWorkspaceShell(
                store: store,
                signOut: signOut,
                showAddDevice: showAddDevice,
                reconnectStoredMac: reconnectStoredMacIfNeeded
            )
        } else if shouldShowOnboarding {
            onboardingFlow
        } else if store.connectionState != .connected && !store.hasKnownPairedMac {
            DisconnectedWorkspaceShellView(
                hasKnownPairedMac: store.hasKnownPairedMac,
                showAddDevice: showAddDevice,
                signOut: signOut,
                setupHelpHighlight: disconnectedSetupHelpHighlight,
                store: store
            )
        } else {
            WorkspaceShellView(store: store, signOut: signOut, showAddDevice: showAddDevice)
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

    /// Whether the one-time first-run onboarding should be presented. Always
    /// `false` off iOS (onboarding is iOS-only).
    private var shouldShowOnboarding: Bool {
        #if os(iOS)
        return MobileOnboardingGate.shouldShowOnboarding(
            hasSeenOnboarding: hasSeenOnboarding,
            hasKnownPairedMac: store.hasKnownPairedMac
        )
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var onboardingFlow: some View {
        #if os(iOS)
        OnboardingFlowView(onComplete: completeOnboarding)
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Persists the onboarding "seen" flag and re-renders so the root falls
    /// through to the pairing flow. Called from the onboarding button actions
    /// (Skip / Get started), not a view-lifecycle callback.
    private func completeOnboarding() {
        onboardingStore.markSeen()
        hasSeenOnboarding = true
    }
    #endif

    private var isAuthenticated: Bool {
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication
        )
    }

    private var shouldShowRestoringStoredMac: Bool {
        MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: isAuthenticated,
            connectionState: store.connectionState,
            isReconnectingStoredMac: store.isReconnectingStoredMac,
            hasKnownPairedMac: store.hasKnownPairedMac,
            pairedMacHintUndetermined: store.pairedMacHintUndetermined,
            didFinishStoredMacReconnectAttempt: store.didFinishStoredMacReconnectAttempt
        )
    }

    private var shouldWaitForAuthenticatedUserScope: Bool {
        shouldWaitForAuthenticatedUserScopeBase && !didTimeoutAuthenticatedUserScopeWait
    }

    private var shouldWaitForAuthenticatedUserScopeBase: Bool {
        MobileRootAuthGate.shouldWaitForAuthenticatedUserScope(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
            connectionState: store.connectionState,
            currentUserID: authManager.currentUser?.id
        )
    }

    private var authenticatedUserScopeDeadlineTaskID: Int {
        (authenticatedUserScopeRetryGeneration &* 2) + (shouldWaitForAuthenticatedUserScopeBase ? 1 : 0)
    }

    @MainActor
    private func updateAuthenticatedUserScopeDeadline() async {
        guard shouldWaitForAuthenticatedUserScopeBase else {
            didTimeoutAuthenticatedUserScopeWait = false
            return
        }
        do {
            try await ContinuousClock().sleep(for: Self.authenticatedUserScopeWaitTimeout)
        } catch {
            return
        }
        guard shouldWaitForAuthenticatedUserScopeBase else { return }
        didTimeoutAuthenticatedUserScopeWait = true
    }

    private var hasActiveAttachTicketAuthentication: Bool {
        didAuthenticateWithAttachTicket && store.hasActiveUnexpiredAttachTicket
    }

    private func syncShellAuthentication(
        _ isAuthenticated: Bool,
        isRestoringSession: Bool? = nil
    ) {
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: isAuthenticated,
            isRestoringSession: isRestoringSession ?? authManager.isRestoringSession,
            store: store
        )
    }

    private func reconnectStoredMacIfNeeded() {
        guard isAuthenticated else { return }
        let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
        guard !startedUITestAttachURL,
              MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                attachURLConnectionInProgress: isConnectingLaunchAttachURL,
                connectionState: store.connectionState
              ) else { return }
        guard !shouldWaitForAuthenticatedUserScope,
              let stackUserID = authManager.currentUser?.id else { return }
        Task {
            await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
        }
    }

    private func retryAuthenticatedUserScope() {
        didTimeoutAuthenticatedUserScopeWait = false
        authenticatedUserScopeRetryGeneration &+= 1
        store.resumeForegroundRefresh()
        Task {
            await authManager.revalidateSession()
            reconnectStoredMacIfNeeded()
        }
    }

    private func showAddDevice() {
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
                isShowingAddDeviceSheet = true
            }
            clearAttachTicketAuthentication(after: result)
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
        #if os(iOS)
        // The hook receives the tokens captured before the local-first clear:
        // by the time it runs, the live token store is already empty.
        let pushCoordinator = pushCoordinator
        let onSignedOut: @Sendable (String?, String?) async -> Void = { accessToken, refreshToken in
            await pushCoordinator.unregisterFromServer(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        }
        #else
        let onSignedOut: @Sendable (String?, String?) async -> Void = { _, _ in }
        #endif
        Task {
            // Local shell teardown first so the whole UI lands signed out
            // immediately; authManager.signOut clears the local session up
            // front and only then runs its bounded best-effort server teardown
            // (push-token DELETE, Stack session revocation).
            didAuthenticateWithAttachTicket = false
            store.signOut()
            await authManager.signOut(onSignedOut: onSignedOut)
        }
    }

    @discardableResult
    private func connectUITestAttachURLIfNeeded() -> Bool {
        #if DEBUG
        // Auto-pair when an attach URL is supplied at launch.
        // CMUX_DOGFOOD_ATTACH_URL is not mock-gated, so dev-launch can sign in
        // against the real backend and pair to the freshly built Mac dev app.
        // CMUX_UITEST_ATTACH_URL stays mock-gated for the XCUITest harness.
        // No-op unless one of those env vars is set, so normal launches are
        // unaffected.
        guard !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.dogfoodAttachURL ?? UITestConfig.attachURL else {
            return false
        }
        didConsumeUITestAttachURL = true
        isConnectingLaunchAttachURL = true
        mobileRootViewLog.info("launch attach URL connect started")
        Task { @MainActor in
            let connected = await store.connectPairingURL(attachURL)
            isConnectingLaunchAttachURL = false
            mobileRootViewLog.info("launch attach URL connect finished connected=\(connected, privacy: .public)")
            if !connected, store.connectionState != .connected {
                reconnectStoredMacIfNeeded()
            }
        }
        return true
        #else
        return false
        #endif
    }
}

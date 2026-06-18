import Foundation
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CMUXMobileRootView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthCoordinator.self) private var authManager
    #if os(iOS)
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    /// The persisted first-run onboarding "seen" flag store. The one-time
    /// onboarding screen gates ahead of the never-paired add-device state.
    private let onboardingStore: MobileOnboardingStore
    /// Mirrors ``MobileOnboardingStore/hasSeenOnboarding`` so completing
    /// onboarding (which calls `markSeen()` in the button action) re-renders the
    /// root and falls through to the pairing flow. Seeded synchronously from the
    /// store so the very first frame already reflects a prior install's state and
    /// never flashes onboarding for a returning user.
    @State private var hasSeenOnboarding: Bool
    #endif
    @State private var pendingAttachURL: String?
    @State private var didConsumeUITestAttachURL = false
    @State private var didAuthenticateWithAttachTicket = false
    @State private var isShowingAddDeviceSheet = false
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
            // restoring gate could stay on RestoringSessionView forever because
            // nothing ever resolves `didFinishStoredMacReconnectAttempt`.
            reconnectStoredMacIfNeeded()
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.resumeForegroundRefresh()
            // The user may have toggled Tailscale while we were backgrounded.
            tailscaleStatusMonitor?.refresh()
            // Re-check the Stack session on resume so one that died while
            // backgrounded routes to the sign-in page instead of waiting for a
            // failed connect to surface a confusing host-side message.
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
            WorkspaceListLayoutPreviewView()
        } else if shouldShowRestoringSession {
            RestoringSessionView()
        } else if !isAuthenticated {
            SignInView()
        } else if store.connectionState != .connected && shouldShowRestoringStoredMac {
            if store.hasKnownPairedMac || store.isReconnectingStoredMac {
                // We know a Mac is being reconnected: it is honest to say so.
                RestoringSessionView()
            } else {
                // Still determining whether a paired Mac exists (install predating
                // the hint, or a fresh sign-in): a neutral spinner, since we do not
                // yet know if there is a session to restore.
                MobilePairedMacDeterminingView()
            }
        } else if shouldShowOnboarding {
            // Placed after the reconnect-determining branch so `hasKnownPairedMac`
            // has resolved: a genuine first run (never onboarded, never paired)
            // sees the one-time explainer before the add-device flow; a returning
            // paired-but-offline user (who can reach here after a failed
            // reconnect) is excluded by the gate and falls through to pairing.
            onboardingFlow
        } else if store.connectionState != .connected {
            DisconnectedWorkspaceShellView(
                hasKnownPairedMac: store.hasKnownPairedMac,
                showAddDevice: showAddDevice,
                signOut: signOut,
                setupHelpHighlight: disconnectedSetupHelpHighlight,
                store: store
            )
            .onAppear {
                showAddDevice()
            }
        } else {
            WorkspaceShellView(store: store, signOut: signOut)
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

    private var shouldShowRestoringSession: Bool {
        MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
            isRestoringSession: authManager.isRestoringSession
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

    /// Starts the stored-Mac reconnect when authenticated, unless a UITest attach
    /// URL took over. Called from both initial `onAppear` (covers a mount that is
    /// already authenticated) and `onChange(of: isAuthenticated)` (covers a
    /// sign-in that completes after mount) so the restoring gate always resolves
    /// even when the auth state never transitions while this view is mounted.
    private func reconnectStoredMacIfNeeded() {
        guard isAuthenticated else { return }
        let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
        guard !startedUITestAttachURL,
              MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                connectionState: store.connectionState
              ) else { return }
        let stackUserID = authManager.currentUser?.id
        Task {
            await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
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
        guard !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.dogfoodAttachURL ?? UITestConfig.attachURL else {
            return false
        }
        didConsumeUITestAttachURL = true
        Task {
            await store.connectPairingURL(attachURL)
        }
        return true
        #else
        return false
        #endif
    }
}

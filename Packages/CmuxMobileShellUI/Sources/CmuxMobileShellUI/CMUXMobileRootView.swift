import Foundation
import CmuxAuthRuntime
import CmuxMobileShell
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
    #endif
    @State private var pendingAttachURL: String?
    @State private var didConsumeUITestAttachURL = false
    @State private var didAuthenticateWithAttachTicket = false
    @State private var isShowingAddDeviceSheet = true
    #if os(iOS)
    @State private var addDeviceSheetDetent: PresentationDetent = .large
    #endif

    var body: some View {
        rootContent
        .animation(.snappy(duration: 0.18), value: isAuthenticated)
        .animation(.snappy(duration: 0.18), value: store.phase)
        .onAppear {
            syncShellAuthentication(isAuthenticated)
            store.resumeForegroundRefresh()
            connectUITestAttachURLIfNeeded()
            #if os(iOS)
            pushCoordinator.bind(store: store)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.resumeForegroundRefresh()
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
            if let rawURL = pendingAttachURL {
                pendingAttachURL = nil
                Task {
                    await store.connectPairingURL(rawURL)
                }
                return
            }
            let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
            if !startedUITestAttachURL,
               MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                connectionState: store.connectionState
            ) {
                let stackUserID = authManager.currentUser?.id
                Task {
                    await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
                }
            }
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
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
        if shouldShowRestoringSession {
            RestoringSessionView()
        } else if !isAuthenticated {
            SignInView()
        } else if store.connectionState != .connected {
            DisconnectedWorkspaceShellView(
                showAddDevice: showAddDevice,
                signOut: signOut
            )
            .sheet(isPresented: $isShowingAddDeviceSheet) {
                PairingView(
                    pairingCode: $store.pairingCode,
                    connectionError: store.connectionError,
                    connectPairingCode: {
                        await store.connectPairingInput()
                    },
                    connectManualHost: { name, host, port in
                        await store.connectManualHost(name: name, host: host, port: port)
                    },
                    cancelPairing: store.cancelPairing,
                    cancel: { isShowingAddDeviceSheet = false }
                )
                #if os(iOS)
                .presentationDetents([.medium, .large], selection: $addDeviceSheetDetent)
                .presentationDragIndicator(.visible)
                #endif
            }
            .onAppear {
                showAddDevice()
            }
        } else {
            WorkspaceShellView(store: store, signOut: signOut)
        }
    }

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

    private func showAddDevice() {
        #if os(iOS)
        addDeviceSheetDetent = .large
        #endif
        isShowingAddDeviceSheet = true
    }

    private func connectAttachURL(_ rawURL: String) {
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication(true)
        Task {
            let result = await store.connectPairingURLResult(rawURL)
            guard MobileRootAuthGate.shouldClearAttachTicketAuthentication(
                pairingResult: result,
                connectionState: store.connectionState,
                hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
            ) else { return }
            didAuthenticateWithAttachTicket = false
            syncShellAuthentication(authManager.isAuthenticated)
        }
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
        let pushCoordinator = pushCoordinator
        let onSignedOut: @Sendable () async -> Void = { await pushCoordinator.unregisterFromServer() }
        #else
        let onSignedOut: @Sendable () async -> Void = {}
        #endif
        Task {
            await authManager.signOut(onSignedOut: onSignedOut)
            didAuthenticateWithAttachTicket = false
            store.signOut()
        }
    }

    @discardableResult
    private func connectUITestAttachURLIfNeeded() -> Bool {
        #if DEBUG
        // Auto-pair when CMUX_UITEST_ATTACH_URL is supplied at launch. Originally
        // gated on mock data (the XCUITest harness), but the dev-launch tooling
        // (scripts/mobile-dev-launch.sh) signs in for real (CMUX_UITEST_STACK_*
        // with CMUX_UITEST_MOCK_DATA=0) and still wants to auto-attach, so this
        // fires for any authenticated session once the attach URL is present.
        // No-op unless that env var is set, so normal launches are unaffected.
        guard !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.attachURL else {
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

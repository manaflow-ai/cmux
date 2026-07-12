import CmuxAuthRuntime
import CmuxMobileBrowser
import CmuxMobileShell
import SwiftUI
#if os(iOS)
import CmuxMobileShellModel
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @State private var store: CMUXMobileShellStore
    /// This scene's phone browser store, injected into the environment. Unlike
    /// terminals, browser state has no Mac-side counterpart and must survive
    /// view reconstruction and workspace re-syncs.
    @State var browserStore: BrowserSurfaceStore
    #if os(iOS)
    private let onboardingStore: MobileOnboardingStore
    #endif

    #if os(iOS)
    /// Creates the app view.
    /// - Parameters:
    ///   - store: The shell store backing the workspace UI.
    ///   - browserStore: The phone-local browser surface store injected into the
    ///     environment for workspace detail browser panes.
    ///   - onboardingStore: The first-run onboarding "seen" flag store. Defaults
    ///     to a `.standard`-backed store marked already-seen, so SwiftUI previews
    ///     and ad-hoc construction never present onboarding.
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore,
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceSeen: true)
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
        self.onboardingStore = onboardingStore
    }
    #else
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(store: store, onboardingStore: onboardingStore)
            .environment(browserStore)
            .onAppear(perform: synchronizeBrowserPersistenceScope)
            .onChange(of: browserPersistenceScope) { _, _ in
                synchronizeBrowserPersistenceScope()
            }
            .onChange(of: store.connectionState) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
            .onChange(of: store.browserWorkspaceListIsAuthoritative) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
            .onChange(of: browserWorkspaceIdentities) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
        #else
        CMUXMobileRootView(store: store)
            .environment(browserStore)
            .onAppear(perform: synchronizeBrowserPersistenceScope)
            .onChange(of: browserPersistenceScope) { _, _ in
                synchronizeBrowserPersistenceScope()
            }
            .onChange(of: store.connectionState) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
            .onChange(of: store.browserWorkspaceListIsAuthoritative) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
            .onChange(of: browserWorkspaceIdentities) { _, _ in
                reconcileBrowserSurfacesIfAuthoritative()
            }
        #endif
    }

    private var browserWorkspaceIdentities: [BrowserWorkspaceIdentity] {
        WorkspaceBrowserReconciliation(workspaces: store.workspaces).identities
    }

    private var browserPersistenceScope: BrowserPersistenceScope? {
        guard authManager.isAuthenticated,
              let userID = authManager.currentUser?.id,
              !userID.isEmpty else { return nil }
        return BrowserPersistenceScope(userID: userID, teamID: authManager.selectedTeamID)
    }

    private func synchronizeBrowserPersistenceScope() {
        browserStore.setPersistenceScope(browserPersistenceScope)
        reconcileBrowserSurfacesIfAuthoritative()
    }

    private func reconcileBrowserSurfacesIfAuthoritative() {
        // A connected store has already applied its initial workspace list.
        // Before that point an empty list is transitional and must not erase
        // restorable browser sessions from the prior launch.
        guard store.connectionState == .connected,
              store.browserWorkspaceListIsAuthoritative else { return }
        browserStore.reconcileWorkspaces(browserWorkspaceIdentities)
    }
}

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
    @State private var store: CMUXMobileShellStore
    /// Phone-local browser surfaces, owned for the app's lifetime and injected
    /// into the environment so the workspace detail view can present a browser
    /// pane without threading the store through every intermediate view. Browser
    /// state lives here (not in the shell store) because, unlike terminals, it
    /// has no Mac-side counterpart and must survive `workspace.updated` re-syncs.
    @State private var browserStore: BrowserSurfaceStore
    /// App-lifetime owner for the initial explicit-attach versus saved-Mac
    /// reconnect decision. Root view lifecycle callbacks share this instance.
    @State private var startupConnectionCoordinator = MobileStartupConnectionCoordinator()
    private let signOutHook: MobileSignOutHook
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
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceSeen: true),
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
    }
    #else
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore(),
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
        self.signOutHook = signOutHook
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(
            store: store,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook,
            startupConnectionCoordinator: startupConnectionCoordinator
        )
            .environment(browserStore)
        #else
        CMUXMobileRootView(
            store: store,
            signOutHook: signOutHook,
            startupConnectionCoordinator: startupConnectionCoordinator
        )
            .environment(browserStore)
        #endif
    }
}

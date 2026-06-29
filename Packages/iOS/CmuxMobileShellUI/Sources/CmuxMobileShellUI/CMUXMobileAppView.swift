import CmuxMobileBrowser
import CmuxAuthRuntime
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
    #if os(iOS)
    private let onboardingStore: MobileOnboardingStore
    private let authCallbackRouter: AuthCallbackRouter?
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
        authCallbackRouter: AuthCallbackRouter? = nil
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
        self.onboardingStore = onboardingStore
        self.authCallbackRouter = authCallbackRouter
    }
    #else
    public init(
        store: CMUXMobileShellStore = .preview(),
        browserStore: BrowserSurfaceStore = BrowserSurfaceStore()
    ) {
        _store = State(initialValue: store)
        _browserStore = State(initialValue: browserStore)
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(
            store: store,
            onboardingStore: onboardingStore,
            authCallbackRouter: authCallbackRouter
        )
            .environment(browserStore)
        #else
        CMUXMobileRootView(store: store)
            .environment(browserStore)
        #endif
    }
}

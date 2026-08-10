import SwiftUI
#if os(iOS)
import CmuxMobileShellModel
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var session: MobileShellUISession
    private let signOutHook: MobileSignOutHook
    #if os(iOS)
    private let onboardingStore: MobileOnboardingStore
    #endif

    #if os(iOS)
    /// Creates the app view around one stable UI-lifecycle owner.
    /// - Parameters:
    ///   - session: The shell and UI-local state graph.
    ///   - onboardingStore: The first-run onboarding progress store. Defaults to
    ///     a `.standard`-backed store forced complete, so SwiftUI previews and
    ///     ad-hoc construction never present onboarding.
    ///   - signOutHook: The action invoked when the mobile shell signs out.
    public init(
        session: MobileShellUISession,
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceComplete: true),
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _session = State(initialValue: session)
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
    }
    #else
    /// Creates the app view on non-iOS platforms.
    /// - Parameters:
    ///   - session: The shell and UI-local state graph.
    ///   - signOutHook: The action invoked when the mobile shell signs out.
    public init(
        session: MobileShellUISession,
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _session = State(initialValue: session)
        self.signOutHook = signOutHook
    }
    #endif

    /// Renders the platform root view with app-lifetime browser stores injected.
    public var body: some View {
        #if os(iOS)
        CMUXMobileAppSessionView(
            session: session,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        #else
        CMUXMobileAppSessionView(session: session, signOutHook: signOutHook)
        #endif
    }
}

/// Renders a caller-owned session without adding another SwiftUI state owner.
package struct CMUXMobileAppSessionView: View {
    let session: MobileShellUISession
    let signOutHook: MobileSignOutHook
    #if os(iOS)
    let onboardingStore: MobileOnboardingStore

    package init(
        session: MobileShellUISession,
        onboardingStore: MobileOnboardingStore,
        signOutHook: MobileSignOutHook
    ) {
        self.session = session
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
    }
    #else
    package init(session: MobileShellUISession, signOutHook: MobileSignOutHook) {
        self.session = session
        self.signOutHook = signOutHook
    }
    #endif

    package var body: some View {
        #if os(iOS)
        CMUXMobileRootView(
            store: session.store,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook,
            startupConnectionCoordinator: session.startupConnectionCoordinator
        )
            .environment(session.browserStore)
            .environment(session.browserStreamStore)
            .environment(session.simulatorStreamStore)
            .environment(session.terminalRuntimeOwner)
        #else
        CMUXMobileRootView(
            store: session.store,
            signOutHook: signOutHook,
            startupConnectionCoordinator: session.startupConnectionCoordinator
        )
            .environment(session.browserStore)
            .environment(session.browserStreamStore)
            .environment(session.simulatorStreamStore)
        #endif
    }
}

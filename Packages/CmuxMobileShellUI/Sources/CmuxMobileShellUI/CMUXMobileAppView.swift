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
    #if os(iOS)
    private let onboardingStore: MobileOnboardingStore
    #endif

    #if os(iOS)
    /// Creates the app view.
    /// - Parameters:
    ///   - store: The shell store backing the workspace UI.
    ///   - onboardingStore: The first-run onboarding "seen" flag store. Defaults
    ///     to a `.standard`-backed store marked already-seen, so SwiftUI previews
    ///     and ad-hoc construction never present onboarding.
    public init(
        store: CMUXMobileShellStore = .preview(),
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceSeen: true)
    ) {
        _store = State(initialValue: store)
        self.onboardingStore = onboardingStore
    }
    #else
    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(store: store, onboardingStore: onboardingStore)
        #else
        CMUXMobileRootView(store: store)
        #endif
    }
}

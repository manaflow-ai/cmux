import AppKit
import Foundation

/// Presents the one-time "Welcome to cmux Pro" checklist after a user becomes
/// Pro. The checklist is a chromeless in-app web page (`/app-pro-welcome`)
/// shown in the same dedicated workspace surface as the pricing page, so it
/// matches how upgrade/pricing already appears. Automatic presentation is
/// gated on Pro status, a persisted seen-flag, and the Pro upgrade UI feature
/// flag; manual and debug entrypoints call `present()` directly.
enum ProWelcomeChecklistPresenter {
    static let seenDefaultsKey = "cmux.pro.welcomeChecklist.seen"

    static func shouldPresentAutomatically(isPro: Bool, seen: Bool, flagEnabled: Bool) -> Bool {
        isPro && !seen && flagEnabled
    }

    /// Whether the automatic checklist could plausibly be shown, ignoring the
    /// Pro status that only a network fetch can determine. Lets callers skip
    /// the `/api/billing/plan` fetch entirely when the checklist is already
    /// seen or the Pro upgrade UI flag is off (the common Release path).
    static func canPresentAutomatically(
        flagEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        flagEnabled && !defaults.bool(forKey: seenDefaultsKey)
    }

    static func consumeAutomaticPresentation(
        isPro: Bool,
        flagEnabled: Bool,
        defaults: UserDefaults
    ) -> Bool {
        let seen = defaults.bool(forKey: seenDefaultsKey)
        guard shouldPresentAutomatically(isPro: isPro, seen: seen, flagEnabled: flagEnabled) else {
            return false
        }
        defaults.set(true, forKey: seenDefaultsKey)
        return true
    }

    @MainActor
    static func present(tabManager: TabManager? = nil) {
        ProUpgradePresenter.presentProWelcomeWeb(tabManager: tabManager)
    }

    @MainActor
    static func presentIfNewlyPro(isPro: Bool, defaults: UserDefaults = .standard) {
        guard consumeAutomaticPresentation(
            isPro: isPro,
            flagEnabled: CmuxFeatureFlags.shared.isProUpgradeUIEnabled,
            defaults: defaults
        ) else {
            return
        }
        present()
    }
}

extension ProUpgradePresenter {
    /// Opens the in-app "Welcome to cmux Pro" checklist as a chromeless web page in the
    /// same dedicated workspace surface used for pricing, matching upgrade/pricing.
    @MainActor
    static func presentProWelcomeWeb(tabManager: TabManager? = nil) {
        if let tabManager,
           AppDelegate.shared?.liveMainWindowContextForAction(tabManager: tabManager) == nil {
            return
        }
        let url = decoratedAppWebURL(AuthEnvironment.appProWelcomeURL)
        guard BrowserAvailabilitySettings.isEnabled() else {
            NSWorkspace.shared.open(url)
            return
        }
        if presentDedicatedProWelcomeWorkspace(url: url, tabManager: tabManager) {
            return
        }
        presentBrowserSplit(url: url, transparentBackground: true, tabManager: tabManager)
    }

    @MainActor
    private static func presentDedicatedProWelcomeWorkspace(
        url: URL,
        tabManager: TabManager?
    ) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        let reuseContext = appDelegate.proUpgradeWorkspaceReuseContext(
            tabManager: tabManager,
            debugSource: "proWelcomeChecklist.reuse"
        )
        let targetManager = reuseContext?.tabManager ?? tabManager
        if let reuseContext,
           let workspaceId = reusableProWorkspaceID(
               &reuseContext.proWelcomeWorkspaceId,
               exists: {
                   appDelegate.proUpgradeWorkspaceExists(
                       workspaceId: $0,
                       tabManager: reuseContext.tabManager
                   )
               }
           ) {
            if appDelegate.focusProUpgradeWorkspace(
                workspaceId: workspaceId,
                url: url,
                tabManager: reuseContext.tabManager
            ) {
                return true
            }
            reuseContext.proWelcomeWorkspaceId = nil
        }

        let title = String(localized: "proWelcome.workspace.title", defaultValue: "Welcome to cmux Pro")
        guard let workspace = appDelegate.performProUpgradeWorkspaceAction(
            title: title,
            url: url,
            tabManager: targetManager,
            debugSource: "proWelcomeChecklist"
        ) else {
            return false
        }
        if let ownerManager = workspace.owningTabManager,
           let ownerContext = appDelegate.mainWindowContext(for: ownerManager) {
            ownerContext.proWelcomeWorkspaceId = workspace.id
        }
        return true
    }

    /// Builds an app web URL (pricing or Pro welcome) decorated with the current
    /// appearance, background color, and cmux app/scheme query parameters.
    @MainActor
    static func decoratedAppWebURL(_ base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "appearance" }
        queryItems.removeAll { $0.name == "background" }
        queryItems.removeAll { $0.name == "cmux_app" }
        queryItems.removeAll { $0.name == "cmux_scheme" }
        let backgroundColor = GhosttyBackgroundTheme.currentColor()
        let appearance = cmuxReadableColorScheme(for: backgroundColor) == .dark ? "dark" : "light"
        queryItems.append(URLQueryItem(name: "appearance", value: appearance))
        queryItems.append(URLQueryItem(name: "background", value: backgroundColor.hexString()))
        queryItems.append(URLQueryItem(name: "cmux_app", value: "1"))
        queryItems.append(URLQueryItem(name: "cmux_scheme", value: AuthEnvironment.callbackScheme))
        components?.queryItems = queryItems
        return components?.url ?? base
    }
}

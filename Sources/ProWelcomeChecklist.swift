import AppKit
import CmuxTerminalCore
import Foundation

struct AppWebThemeSnapshot: Equatable {
    let appearance: String
    let background: String
    let foreground: String
    let accent: String

    private struct JavaScriptPayload: Encodable {
        let appearance: String
        let background: String
        let foreground: String
        let accent: String
    }

    static func current(notification: Notification? = nil) -> AppWebThemeSnapshot {
        let userInfo = notification?.userInfo
        let backgroundColor = GhosttyBackgroundTheme.color(from: notification)
        let foregroundColor =
            (userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor)
            ?? GhosttyApp.shared.defaultForegroundColor
        let config = GhosttyConfig.load(
            preferredColorScheme: GhosttyApp.shared.effectiveTerminalColorSchemePreference
        )
        return resolved(
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            palette: config.palette
        )
    }

    static func resolved(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        palette: [Int: NSColor]
    ) -> AppWebThemeSnapshot {
        let appearance = cmuxReadableColorScheme(for: backgroundColor) == .dark ? "dark" : "light"
        return AppWebThemeSnapshot(
            appearance: appearance,
            background: backgroundColor.hexString(),
            foreground: foregroundColor.hexString(),
            accent: vividAccent(palette: palette, foregroundColor: foregroundColor, against: backgroundColor)
                .hexString()
        )
    }

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "appearance", value: appearance),
            URLQueryItem(name: "background", value: background),
            URLQueryItem(name: "foreground", value: foreground),
            URLQueryItem(name: "accent", value: accent),
        ]
    }

    func applyingJavaScript() -> String? {
        let payload = JavaScriptPayload(
            appearance: appearance,
            background: background,
            foreground: foreground,
            accent: accent
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return """
        (() => {
          const root = document.querySelector('[data-cmux-app-theme]');
          if (!root) return false;
          const theme = \(json);
          root.style.setProperty('--ghostty-background', theme.background);
          root.style.setProperty('--ghostty-foreground', theme.foreground);
          root.style.setProperty('--ghostty-accent', theme.accent);
          root.style.backgroundColor = theme.background;
          root.style.colorScheme = theme.appearance;
          root.dataset.cmuxAppThemeAppearance = theme.appearance;
          if (root.hasAttribute('data-app-pricing-appearance')) {
            root.setAttribute('data-app-pricing-appearance', theme.appearance);
          }
          if (root.hasAttribute('data-app-pro-welcome-appearance')) {
            root.setAttribute('data-app-pro-welcome-appearance', theme.appearance);
          }
          for (const element of [document.documentElement, document.body]) {
            element?.style.setProperty('background', theme.background, 'important');
          }
          document.querySelector('meta[name="theme-color"]')
            ?.setAttribute('content', theme.background);
          return true;
        })()
        """
    }

    static func supports(url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.path == "/app-pricing" || url.path == "/app-pro-welcome"
    }

    private static func vividAccent(
        palette: [Int: NSColor],
        foregroundColor: NSColor,
        against target: NSColor
    ) -> NSColor {
        let paletteOrder = [12, 14, 13, 10, 11, 9, 4, 6, 5, 2, 3, 1]
        let candidates = paletteOrder.compactMap { palette[$0] } + [foregroundColor]
        return candidates.max { accentScore($0, against: target) < accentScore($1, against: target) }
            ?? foregroundColor
    }

    private static func accentScore(_ color: NSColor, against target: NSColor) -> Double {
        let contrast = color.markdownContrastRatio(with: target)
        let saturation = color.usingColorSpace(.sRGB).map { rgb -> CGFloat in
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return saturation
        } ?? 0
        let contrastTier = contrast >= 4.5 ? 2.0 : (contrast >= 3.0 ? 1.0 : 0.0)
        return (contrastTier * 100.0) + (Double(saturation) * 10.0) + min(contrast, 10.0)
    }
}

/// Presents the one-time "Welcome to cmux Pro" checklist after a user becomes
/// Pro. The checklist is a chromeless in-app web page (`/app-pro-welcome`)
/// shown in the same dedicated workspace surface as the pricing page, so it
/// matches how upgrade/pricing already appears. Automatic presentation is
/// gated on Pro status, a persisted seen-flag, and the Pro upgrade UI feature
/// flag; manual and debug entrypoints call `present()` directly.
enum ProWelcomeChecklistPresenter {
    static let seenDefaultsKey = "cmux.pro.welcomeChecklist.seen"

    /// Tracks the dedicated welcome workspace so repeated presentations reuse
    /// and focus it instead of spawning a duplicate workspace each time.
    @MainActor
    static var workspaceReuseState = ProUpgradeWorkspaceReuseState()

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
    static func present() {
        ProUpgradePresenter.presentProWelcomeWeb()
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
    static func presentProWelcomeWeb() {
        let url = decoratedAppWebURL(AuthEnvironment.appProWelcomeURL)
        guard BrowserAvailabilitySettings.isEnabled() else {
            NSWorkspace.shared.open(url)
            return
        }
        if presentDedicatedProWelcomeWorkspace(url: url) {
            return
        }
        presentBrowserSplit(url: url, transparentBackground: true)
    }

    @MainActor
    private static func presentDedicatedProWelcomeWorkspace(url: URL) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        if let workspaceId = ProWelcomeChecklistPresenter.workspaceReuseState.reusableWorkspaceID(
            exists: { appDelegate.proUpgradeWorkspaceExists(workspaceId: $0) }
        ) {
            if appDelegate.focusProUpgradeWorkspace(workspaceId: workspaceId, url: url) {
                return true
            }
            ProWelcomeChecklistPresenter.workspaceReuseState.clear()
        }

        let title = String(localized: "proWelcome.workspace.title", defaultValue: "Welcome to cmux Pro")
        guard let workspace = appDelegate.performProUpgradeWorkspaceAction(
            title: title,
            url: url,
            debugSource: "proWelcomeChecklist"
        ) else {
            return false
        }
        ProWelcomeChecklistPresenter.workspaceReuseState.recordCreatedWorkspace(id: workspace.id)
        return true
    }

    /// Builds an app web URL (pricing or Pro welcome) decorated with the current
    /// Ghostty colors and cmux app/scheme query parameters.
    @MainActor
    static func decoratedAppWebURL(_ base: URL) -> URL {
        decoratedAppWebURL(base, theme: AppWebThemeSnapshot.current())
    }

    static func decoratedAppWebURL(_ base: URL, theme: AppWebThemeSnapshot) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        let themedQueryNames = Set(theme.queryItems.map(\.name))
        queryItems.removeAll { themedQueryNames.contains($0.name) }
        queryItems.removeAll { $0.name == "cmux_app" }
        queryItems.removeAll { $0.name == "cmux_scheme" }
        queryItems.append(contentsOf: theme.queryItems)
        queryItems.append(URLQueryItem(name: "cmux_app", value: "1"))
        queryItems.append(URLQueryItem(name: "cmux_scheme", value: AuthEnvironment.callbackScheme))
        components?.queryItems = queryItems
        return components?.url ?? base
    }
}

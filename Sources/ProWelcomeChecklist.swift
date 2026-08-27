import AppKit
import CmuxBrowser
import CmuxTerminalCore
import Foundation

@MainActor
struct AppWebThemeSnapshot: Equatable {
    let appearance: String
    let background: String
    let foreground: String
    let accent: String

    static func current(notification: Notification? = nil) -> AppWebThemeSnapshot {
        let userInfo = notification?.userInfo
        let backgroundColor = GhosttyBackgroundTheme.color(from: notification)
        let foregroundColor =
            (userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor)
            ?? GhosttyApp.shared.defaultForegroundColor
        return resolved(
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor
        )
    }

    static func resolved(
        backgroundColor: NSColor,
        foregroundColor: NSColor
    ) -> AppWebThemeSnapshot {
        let colorScheme = cmuxReadableColorScheme(for: backgroundColor)
        let appearance = colorScheme == .dark ? "dark" : "light"
        return AppWebThemeSnapshot(
            appearance: appearance,
            background: backgroundColor.hexString(),
            foreground: foregroundColor.hexString(),
            accent: cmuxAccentNSColor(for: colorScheme).hexString()
        )
    }

    var accentOnBackground: String {
        contrastAdjustedAccent(on: background)
    }

    var accentOnForeground: String {
        contrastAdjustedAccent(on: foreground)
    }

    var browserTheme: BrowserAppTheme {
        BrowserAppTheme(
            appearance: appearance,
            background: background,
            foreground: foreground,
            accent: accent,
            accentOnBackground: accentOnBackground,
            accentOnForeground: accentOnForeground
        )
    }

    private func contrastAdjustedAccent(on backgroundHex: String) -> String {
        guard let accentColor = NSColor(hex: accent),
              let backgroundColor = NSColor(hex: backgroundHex) else {
            return accent
        }
        return Self.contrastAdjustedAccentNSColor(
            accentColor,
            on: backgroundColor
        ).hexString()
    }

    /// Preserves the preferred app-web accent whenever it is readable,
    /// otherwise makes the smallest 8-bit sRGB move toward white or black that
    /// reaches the requested contrast.
    static func contrastAdjustedAccentNSColor(
        _ preferredColor: NSColor,
        on backgroundColor: NSColor,
        minimumContrast: CGFloat = 4.5
    ) -> NSColor {
        let preferred = RGBBytes(color: preferredColor).color
        let background = RGBBytes(color: backgroundColor).color
        guard cmuxContrastRatio(
            foreground: preferred,
            background: background
        ) < minimumContrast else {
            return preferred
        }

        let candidates = [0, 255].compactMap { targetComponent in
            contrastAdjustmentCandidate(
                preferred: RGBBytes(color: preferred),
                background: background,
                targetComponent: targetComponent,
                minimumContrast: minimumContrast
            )
        }
        if let candidate = candidates.min(by: {
            if $0.distanceSquared == $1.distanceSquared {
                return $0.contrast > $1.contrast
            }
            return $0.distanceSquared < $1.distanceSquared
        }) {
            return candidate.color
        }

        return cmuxContrastRatio(foreground: .white, background: background)
            >= cmuxContrastRatio(foreground: .black, background: background)
            ? .white
            : .black
    }

    private struct RGBBytes {
        let red: Int
        let green: Int
        let blue: Int

        init(color: NSColor) {
            let value = UInt64(color.hexString().dropFirst(), radix: 16) ?? 0
            red = Int((value >> 16) & 0xFF)
            green = Int((value >> 8) & 0xFF)
            blue = Int(value & 0xFF)
        }

        init(red: Int, green: Int, blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var color: NSColor {
            NSColor(
                srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }

        func mixed(toward targetComponent: Int, step: Int) -> RGBBytes {
            func mix(_ component: Int) -> Int {
                (component * (255 - step) + targetComponent * step) / 255
            }
            return RGBBytes(
                red: mix(red),
                green: mix(green),
                blue: mix(blue)
            )
        }

        func squaredDistance(to other: RGBBytes) -> Int {
            let redDistance = red - other.red
            let greenDistance = green - other.green
            let blueDistance = blue - other.blue
            return redDistance * redDistance
                + greenDistance * greenDistance
                + blueDistance * blueDistance
        }
    }

    private struct ContrastAdjustmentCandidate {
        let color: NSColor
        let distanceSquared: Int
        let contrast: CGFloat
    }

    private static func contrastAdjustmentCandidate(
        preferred: RGBBytes,
        background: NSColor,
        targetComponent: Int,
        minimumContrast: CGFloat
    ) -> ContrastAdjustmentCandidate? {
        for step in 1...255 {
            let adjusted = preferred.mixed(
                toward: targetComponent,
                step: step
            )
            let color = adjusted.color
            let contrast = cmuxContrastRatio(
                foreground: color,
                background: background
            )
            if contrast >= minimumContrast {
                return ContrastAdjustmentCandidate(
                    color: color,
                    distanceSquared: preferred.squaredDistance(to: adjusted),
                    contrast: contrast
                )
            }
        }
        return nil
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

    @MainActor
    static func decoratedAppWebURL(_ base: URL, theme: AppWebThemeSnapshot) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        let browserTheme = theme.browserTheme
        let themedQueryNames = Set(browserTheme.queryItems.map(\.name))
        queryItems.removeAll { themedQueryNames.contains($0.name) }
        queryItems.removeAll { $0.name == "cmux_app" }
        queryItems.removeAll { $0.name == "cmux_scheme" }
        queryItems.append(contentsOf: browserTheme.queryItems)
        queryItems.append(URLQueryItem(name: "cmux_app", value: "1"))
        queryItems.append(URLQueryItem(name: "cmux_scheme", value: AuthEnvironment.callbackScheme))
        components?.queryItems = queryItems
        return components?.url ?? base
    }
}

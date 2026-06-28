public import SwiftUI

/// Pure value snapshot driving the browser top-chrome toolbar/accessory button
/// cluster (navigation bar, screenshot, focus mode, React Grab, developer
/// tools, profile, theme, import, overflow menu).
///
/// Every field is already resolved app-side: panel booleans, the chrome metrics
/// the buttons size against, the developer-tools tint/icon and theme tint/icon,
/// and all `String(localized:)` help/label strings (the catalog keys bind to the
/// app bundle, so localization stays app-side and the resolved strings are
/// passed through here). Holding only `Sendable` values keeps the toolbar views
/// renderable in this package without reaching back into the app target.
public struct BrowserToolbarSnapshot: Sendable {
    // Navigation state.
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    public var isDownloading: Bool

    // Chrome metrics (derived from the tab bar font size app-side).
    public var navigationIconFontSize: CGFloat
    public var buttonHitSize: CGFloat
    public var accessoryIconFontSize: CGFloat
    public var buttonSize: CGFloat

    // Screenshot button state.
    public var screenshotCopied: Bool
    public var screenshotCaptureInProgress: Bool
    public var shouldRenderWebView: Bool

    // React Grab state.
    public var isReactGrabActive: Bool

    // Browser focus-mode state.
    public var isBrowserFocusModeActive: Bool
    public var isBrowserFocusModeExitArmed: Bool
    public var canToggleBrowserFocusMode: Bool

    // Developer-tools and theme button visuals.
    public var devToolsTint: Color
    public var devToolsIconName: String
    public var themeIconName: String
    public var themeIconColor: Color

    // Pre-localized navigation strings.
    public var goBackHelp: String
    public var goForwardHelp: String
    public var reloadOrStopHelp: String
    public var reloadLabel: String
    public var hardRefreshLabel: String
    public var downloadingText: String
    public var downloadInProgressHelp: String

    // Pre-localized accessory strings.
    public var screenshotHelp: String
    public var screenshotCopiedLabel: String
    public var focusModeArmedText: String
    public var focusModeActiveText: String
    public var focusModeHelp: String
    public var reactGrabHelp: String
    public var devToolsHelp: String
    public var profileHelp: String
    public var themeHelp: String
    public var importToolbarText: String
    public var importHelp: String

    // Pre-localized overflow-menu strings.
    public var focusModeEnterText: String
    public var screenshotCopyHelp: String
    public var reactGrabText: String
    public var moreActionsHelp: String

    /// Creates the toolbar snapshot from values already resolved app-side.
    public init(
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        isDownloading: Bool,
        navigationIconFontSize: CGFloat,
        buttonHitSize: CGFloat,
        accessoryIconFontSize: CGFloat,
        buttonSize: CGFloat,
        screenshotCopied: Bool,
        screenshotCaptureInProgress: Bool,
        shouldRenderWebView: Bool,
        isReactGrabActive: Bool,
        isBrowserFocusModeActive: Bool,
        isBrowserFocusModeExitArmed: Bool,
        canToggleBrowserFocusMode: Bool,
        devToolsTint: Color,
        devToolsIconName: String,
        themeIconName: String,
        themeIconColor: Color,
        goBackHelp: String,
        goForwardHelp: String,
        reloadOrStopHelp: String,
        reloadLabel: String,
        hardRefreshLabel: String,
        downloadingText: String,
        downloadInProgressHelp: String,
        screenshotHelp: String,
        screenshotCopiedLabel: String,
        focusModeArmedText: String,
        focusModeActiveText: String,
        focusModeHelp: String,
        reactGrabHelp: String,
        devToolsHelp: String,
        profileHelp: String,
        themeHelp: String,
        importToolbarText: String,
        importHelp: String,
        focusModeEnterText: String,
        screenshotCopyHelp: String,
        reactGrabText: String,
        moreActionsHelp: String
    ) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.isDownloading = isDownloading
        self.navigationIconFontSize = navigationIconFontSize
        self.buttonHitSize = buttonHitSize
        self.accessoryIconFontSize = accessoryIconFontSize
        self.buttonSize = buttonSize
        self.screenshotCopied = screenshotCopied
        self.screenshotCaptureInProgress = screenshotCaptureInProgress
        self.shouldRenderWebView = shouldRenderWebView
        self.isReactGrabActive = isReactGrabActive
        self.isBrowserFocusModeActive = isBrowserFocusModeActive
        self.isBrowserFocusModeExitArmed = isBrowserFocusModeExitArmed
        self.canToggleBrowserFocusMode = canToggleBrowserFocusMode
        self.devToolsTint = devToolsTint
        self.devToolsIconName = devToolsIconName
        self.themeIconName = themeIconName
        self.themeIconColor = themeIconColor
        self.goBackHelp = goBackHelp
        self.goForwardHelp = goForwardHelp
        self.reloadOrStopHelp = reloadOrStopHelp
        self.reloadLabel = reloadLabel
        self.hardRefreshLabel = hardRefreshLabel
        self.downloadingText = downloadingText
        self.downloadInProgressHelp = downloadInProgressHelp
        self.screenshotHelp = screenshotHelp
        self.screenshotCopiedLabel = screenshotCopiedLabel
        self.focusModeArmedText = focusModeArmedText
        self.focusModeActiveText = focusModeActiveText
        self.focusModeHelp = focusModeHelp
        self.reactGrabHelp = reactGrabHelp
        self.devToolsHelp = devToolsHelp
        self.profileHelp = profileHelp
        self.themeHelp = themeHelp
        self.importToolbarText = importToolbarText
        self.importHelp = importHelp
        self.focusModeEnterText = focusModeEnterText
        self.screenshotCopyHelp = screenshotCopyHelp
        self.reactGrabText = reactGrabText
        self.moreActionsHelp = moreActionsHelp
    }

    /// Foreground tint for the screenshot button glyph: green right after a
    /// copy, the developer-tools tint while a webview is live, otherwise the
    /// disabled secondary color. Pure derivation of the snapshot fields.
    public var screenshotButtonColor: Color {
        if screenshotCopied {
            return .green
        }
        return shouldRenderWebView ? devToolsTint : Color.secondary
    }
}

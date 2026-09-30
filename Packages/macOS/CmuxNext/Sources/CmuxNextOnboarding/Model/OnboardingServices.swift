public import CmuxNextBrowserImport
public import CmuxNextDesign
public import Foundation

/// What the onboarding window needs from the app. The App implements it
/// over settings, the browser and the action registry;
/// `MockOnboardingServices` runs the window alone (demo, tests).
@MainActor
public protocol OnboardingServices: AnyObject {
    // Welcome
    /// The colors of the user's own Ghostty config (the default choice).
    var ghosttyTheme: ThemeInput { get }
    /// `appearance.theme` in cmux.json now; nil means the Ghostty config.
    var selectedThemeName: String? { get }
    var density: Density { get }
    /// The curated Ghostty themes available on this Mac.
    func loadThemeChoices() async -> [ThemeChoice]
    /// Writes the theme (nil: back to the Ghostty config) and density.
    func applyAppearance(themeName: String?, density: Density)

    // Import
    func detectBrowsers() async -> [BrowserSource]
    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary
    /// Opens the extension's Chrome Web Store page in a Chromium tab, where
    /// one click installs it.
    func installExtension(_ item: ImportedExtension)
    /// Opens imported tabs as browser tabs in the current window.
    func openTabs(_ tabs: [ImportedTab])
    /// Whether browser profiles exist yet (else imports go to the default one).
    var browserProfilesAvailable: Bool { get }

    // Default browser and terminal
    var defaultApps: any DefaultAppRegistering { get }
    /// Opens a URL with the system (System Settings panes).
    func openExternal(_ url: URL)

    // Tour
    /// The current shortcut of an action, for display ("⇧⌘P"), or nil.
    func shortcutDisplay(for actionID: String) -> String?

    // Lifecycle
    /// The window closed; `completed` is false when the user skipped.
    func onboardingDidEnd(completed: Bool)
}

/// System Settings deep links.
public enum SystemSettingsLink {
    /// Privacy & Security > Full Disk Access.
    public static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// Keyboard > Keyboard Shortcuts > Services.
    public static let services = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Services")!
    /// Desktop & Dock (the default web browser menu).
    public static let defaultBrowser = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
}

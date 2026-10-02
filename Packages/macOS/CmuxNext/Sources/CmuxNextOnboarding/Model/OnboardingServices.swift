public import AppKit
public import CmuxNextBrowserImport
public import CmuxNextDesign
public import Foundation

/// What the onboarding window needs from the app. The App implements it
/// over settings, the importer and the default-app registry;
/// `MockOnboardingServices` runs the window alone (demo, tests).
@MainActor
public protocol OnboardingServices: AnyObject {
    // Theme
    /// The colors of the user's own Ghostty config (the default choice).
    var ghosttyTheme: ThemeInput { get }
    /// True when the user's Ghostty config sets a theme or colors; false
    /// means cmux's default (Apple System Colors, light/dark) applies.
    var ghosttyHasOwnTheme: Bool { get }
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
    /// Whether this build can save imported passwords (the browser engine has the store).
    func canImportPasswords() async -> Bool

    // Default browser
    var defaultApps: any DefaultAppRegistering { get }
    /// Opens a URL with the system (System Settings panes).
    func openExternal(_ url: URL)

    // Accounts
    /// Whether the App supplies the accounts step (`makeAccountsStepView`).
    var hasAccountsStep: Bool { get }
    /// The accounts step's body (the accounts feature's view), or nil.
    func makeAccountsStepView() -> NSView?

    // Screen designs (the onboarding gallery)
    /// The picked variant id for `step` (`OnboardingScreenVariant.id`), or nil for the default.
    func variantID(for step: OnboardingModel.Step) -> String?
    func setVariantID(_ id: String?, for step: OnboardingModel.Step)

    // Lifecycle
    /// The window closed; `completed` is false when the user skipped.
    func onboardingDidEnd(completed: Bool)
}

public extension OnboardingServices {
    var ghosttyHasOwnTheme: Bool { true }
    var hasAccountsStep: Bool { false }
    func canImportPasswords() async -> Bool { false }
    func makeAccountsStepView() -> NSView? { nil }
    func variantID(for step: OnboardingModel.Step) -> String? { nil }
    func setVariantID(_ id: String?, for step: OnboardingModel.Step) {}
}

/// System Settings deep links.
public extension URL {
    /// Privacy & Security > Full Disk Access.
    static let systemSettingsFullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// Desktop & Dock (the default web browser menu).
    static let systemSettingsDefaultBrowser = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
}

public import AppKit
public import CmuxNextBrowserImport
public import CmuxNextDesign
public import Foundation

/// What the onboarding window needs from the app. The App implements it
/// over settings, the importer and the default-app registry;
/// `MockOnboardingServices` runs the window alone (demo, tests).
@MainActor
public protocol OnboardingServices: AnyObject {
    // Role
    /// The role step's answer from an earlier run, if any.
    var savedProfile: OnboardingProfile? { get }
    /// Keeps the role step's answer (the onboarding state file).
    func saveProfile(_ profile: OnboardingProfile)

    // First task
    /// Whether the App can run an agent chat in the window (the first-task step).
    var canRunFirstTask: Bool { get }
    /// Where the first task runs.
    var firstTaskFolder: FirstTaskFolder { get }
    /// A new agent chat in `cwd` that sends `prompt` once it connects, or
    /// nil. Asked again when the step is shown again: the App returns the
    /// same chat for the same folder and prompt.
    func makeFirstTaskView(cwd: URL, prompt: String) -> NSView?
    /// Selects `url` in a Finder window.
    func revealInFinder(_ url: URL)

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
    /// The single confirmation before saved passwords are read: Touch ID or
    /// the Mac's password (LocalAuthentication). False when the person
    /// cancels or fails; nothing is read then.
    func authorizePasswordRead(reason: String) async -> Bool

    // Default browser
    var defaultApps: any DefaultAppRegistering { get }
    /// Opens a URL with the system (System Settings panes).
    func openExternal(_ url: URL)

    // Computer use
    /// The helper app's grants, or nil when this build has no computer use
    /// (the step is left out then).
    var computerUsePermissions: (any ComputerUsePermissionSource)? { get }

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
    var savedProfile: OnboardingProfile? { nil }
    func saveProfile(_ profile: OnboardingProfile) {}
    var canRunFirstTask: Bool { false }
    var firstTaskFolder: FirstTaskFolder { .live() }
    func makeFirstTaskView(cwd: URL, prompt: String) -> NSView? { nil }
    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    var ghosttyHasOwnTheme: Bool { true }
    var hasAccountsStep: Bool { false }
    var computerUsePermissions: (any ComputerUsePermissionSource)? { nil }
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

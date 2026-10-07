public import AppKit
public import CmuxNextBrowserImport
public import CmuxNextDesign
public import Foundation

/// What the onboarding window needs from the app. The App implements it
/// over settings, the importer and the default-app registry;
/// `MockOnboardingServices` runs the window alone (demo, tests).
@MainActor
public protocol OnboardingServices: AnyObject {
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

    // Projects
    /// Recent project folders, best first (`RecentProjectScan`).
    func scanAgentProjects() async -> [AgentProject]
    /// A folder from the open panel, or nil when the user cancels.
    func chooseFolder() async -> URL?
    /// Opens each folder as a workspace, in order.
    func openProjects(_ folders: [URL])
    /// The Claude Code and Codex chats cmux can resume, newest first (`AgentChatScan`).
    func scanAgentChats() async -> [AgentChat]
    /// Resumes each chat in an agent tab of its folder's workspace: the one
    /// `openProjects` opened, else a new one. A chat already open is shown.
    func resumeChats(_ chats: [AgentChat])
    // Classic cmux session import
    var canImportClassicSessions: Bool { get }
    func scanClassicSessions() async -> [ClassicSessionWorkspace]
    /// The chat ids (`AgentChat.id`) classic cmux had open in its terminals.
    func scanClassicOpenChats() async -> Set<String>
    func importClassicSessions(_ workspaces: [ClassicSessionWorkspace])
    /// The user's home folder (where the privacy-guarded folders are).
    var homeDirectory: URL { get }

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
    /// The first run is at `step` (shown, or moved to): the App keeps it, so
    /// a relaunch or a rebuilt window resumes there.
    func onboardingDidReach(_ step: OnboardingModel.Step)
}

public extension OnboardingServices {
    func onboardingDidReach(_ step: OnboardingModel.Step) {}
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
    func scanAgentProjects() async -> [AgentProject] { [] }
    func chooseFolder() async -> URL? { nil }
    func openProjects(_ folders: [URL]) {}
    func scanAgentChats() async -> [AgentChat] { [] }
    func resumeChats(_ chats: [AgentChat]) {}
    var canImportClassicSessions: Bool { false }
    func scanClassicSessions() async -> [ClassicSessionWorkspace] {
        await Task.detached { (try? ClassicSessionImporter().read()) ?? [] }.value
    }
    func scanClassicOpenChats() async -> Set<String> {
        await Task.detached { (try? ClassicSessionImporter().readOpenChats()) ?? [] }.value
    }
    func importClassicSessions(_ workspaces: [ClassicSessionWorkspace]) {}
    var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }
}

/// System Settings deep links.
public extension URL {
    /// Privacy & Security > Full Disk Access.
    static let systemSettingsFullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// Desktop & Dock (the default web browser menu).
    static let systemSettingsDefaultBrowser = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
}

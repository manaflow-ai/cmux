public import AppKit
public import CmuxNextBrowserImport
public import CmuxNextDesign
public import Foundation

/// Onboarding services with canned data, for the demo and tests. Records
/// what the flow asked for; never touches settings, browsers or macOS.
@MainActor
public final class MockOnboardingServices: OnboardingServices {
    public var ghosttyTheme: ThemeInput = .ghosttyDefault
    public var ghosttyHasOwnTheme = true
    public var selectedThemeName: String?
    public var density: Density = .compact
    public var themeChoices: [ThemeChoice] = []
    public var sources: [BrowserSource] = []
    public var summary = ImportSummary(batches: [])
    /// When set, `runImport` waits here until the test resumes it.
    public var importGate: CheckedContinuation<Void, Never>?
    public var holdsImport = false
    /// The progress reports `runImport` sends; nil: one, the first profile starting on bookmarks.
    public var reports: [ImportProgress]?
    public var passwordStore = false
    public var accountsView: NSView?
    /// Picked screen variants, by step.
    public var variantIDs: [OnboardingModel.Step: String] = [:]
    /// The role step's answer: what `savedProfile` returns and `saveProfile` replaces.
    public var savedProfile: OnboardingProfile?
    public let defaultApps: any DefaultAppRegistering
    /// What the project scan finds.
    public var agentProjects: [AgentProject] = []
    /// What the folder picker returns.
    public var chosenFolder: URL?
    public var homeDirectory = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
    /// Each `openProjects` call's folders.
    public private(set) var openedProjects: [[URL]] = []

    public private(set) var appliedAppearance: [(String?, Density)] = []
    public private(set) var opened: [URL] = []
    public private(set) var ended: Bool?
    public private(set) var plans: [ImportPlan] = []

    public init(defaultApps: any DefaultAppRegistering = RecordingDefaultApps(appBundleURL: URL(fileURLWithPath: "/Applications/cmux.app"))) {
        self.defaultApps = defaultApps
    }

    public func loadThemeChoices() async -> [ThemeChoice] { themeChoices }

    public func applyAppearance(themeName: String?, density: Density) {
        appliedAppearance.append((themeName, density))
        selectedThemeName = themeName
        self.density = density
    }

    public func detectBrowsers() async -> [BrowserSource] { sources }

    public func scanAgentProjects() async -> [AgentProject] { agentProjects }
    public func chooseFolder() async -> URL? { chosenFolder }
    public func openProjects(_ folders: [URL]) { openedProjects.append(folders) }

    public func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        plans.append(plan)
        if let reports {
            reports.forEach(progress)
        } else if let profile = plan.items.first?.profile {
            progress(ImportProgress(profileIndex: 0, profileCount: plan.items.count, profile: profile, kind: .bookmarks,
                                    fraction: 0.5, counts: ImportCounts(bookmarks: 1)))
        }
        if holdsImport { await withCheckedContinuation { importGate = $0 } }
        try Task.checkCancellation()
        return summary
    }

    public func canImportPasswords() async -> Bool { passwordStore }
    /// What the Touch ID sheet answers, and the reasons it was shown with.
    public var passwordAuthorization = true
    public private(set) var authorizationReasons: [String] = []
    /// While true, a Touch ID request waits for ``answerAuthorizations()``
    /// (the sheet is up).
    public var holdsAuthorization = false
    private var pendingAuthorizations: [CheckedContinuation<Void, Never>] = []
    public func authorizePasswordRead(reason: String) async -> Bool {
        authorizationReasons.append(reason)
        if holdsAuthorization { await withCheckedContinuation { pendingAuthorizations.append($0) } }
        return passwordAuthorization
    }

    /// Ends every Touch ID sheet that is up, with `passwordAuthorization`.
    public func answerAuthorizations() {
        let pending = pendingAuthorizations
        pendingAuthorizations = []
        for continuation in pending { continuation.resume() }
    }

    public func openExternal(_ url: URL) { opened.append(url) }

    public var hasAccountsStep: Bool { accountsView != nil }
    public func makeAccountsStepView() -> NSView? { accountsView }

    public func variantID(for step: OnboardingModel.Step) -> String? { variantIDs[step] }
    public func setVariantID(_ id: String?, for step: OnboardingModel.Step) { variantIDs[step] = id }

    public func saveProfile(_ profile: OnboardingProfile) { savedProfile = profile }

    public func onboardingDidEnd(completed: Bool) { ended = completed }

    /// Sample data for the gallery: four browsers, the given themes and accounts view.
    public static func gallerySample(themes: [ThemeChoice], accountsView: NSView?) -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.themeChoices = themes
        services.accountsView = accountsView
        let day: TimeInterval = 86_400
        let now = Date()
        services.agentProjects = [
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/code/cmux"), sessions: 148, lastActive: now, apps: [.claudeCode, .codex]),
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/code/website"), sessions: 37, lastActive: now - day, apps: [.claudeCode]),
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/Documents/thesis"), sessions: 12, lastActive: now - 3 * day, apps: [.codex]),
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/code/api"), sessions: 9, lastActive: now - 6 * day, apps: [.codex, .opencode]),
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/Desktop/scratch"), sessions: 4, lastActive: now - 9 * day, apps: [.pi]),
            AgentProject(folder: URL(fileURLWithPath: "/Users/demo/code/dotfiles"), sessions: 2, lastActive: now - 40 * day, apps: [.claudeCode]),
        ]
        services.passwordStore = true
        func profile(_ browser: ImportBrowser, _ directory: String, _ name: String) -> BrowserSourceProfile {
            let passwords: DataAvailability = browser.family == .chromium ? .available : .absent
            return BrowserSourceProfile(browser: browser, directoryName: directory, displayName: name, path: URL(fileURLWithPath: "/sample/\(directory)"),
                                        availability: [.bookmarks: .available, .history: .available, .cookies: .available, .passwords: passwords])
        }
        services.sources = [
            BrowserSource(browser: .chrome, appURL: nil, profiles: [profile(.chrome, "Default", "Personal"), profile(.chrome, "Profile 1", "Work")]),
            BrowserSource(browser: .arc, appURL: nil, profiles: [profile(.arc, "Default", "Personal")]),
            BrowserSource(browser: .safari, appURL: nil, profiles: [profile(.safari, "Safari", "Safari")]),
            BrowserSource(browser: .firefox, appURL: nil, profiles: [profile(.firefox, "Profiles/a.default", "default-release")]),
        ]
        return services
    }
}

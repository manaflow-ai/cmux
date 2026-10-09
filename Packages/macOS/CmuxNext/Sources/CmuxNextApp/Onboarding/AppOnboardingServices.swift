import AppKit
import CmuxNextActions
import CmuxNextAccounts
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextTerminal
import LocalAuthentication
import SwiftUI

/// `OnboardingServices` over the app: cmux.json for the theme, the importer
/// (cookies into each profile's Chromium store), the default-app registry
/// (mocked in test launches) and the accounts feature's view.
@MainActor
final class AppOnboardingServices: OnboardingServices {
    unowned let owner: OnboardingService
    var services: AppServices { owner.services }
    /// Workspaces `openProjects` and `resumeChats` opened, by folder path,
    /// once their window lists them; and the chats waiting for one.
    var folderWorkspaces: [String: String] = [:]
    var waitingChats: [String: [AgentChat]] = [:]
    /// Folders whose workspace was asked for and isn't listed yet.
    var openingFolders: Set<String> = []

    init(owner: OnboardingService) {
        self.owner = owner
    }

    var canRunFirstTask: Bool { services.agentTabs.canHostChat }
    var firstTaskFolder: FirstTaskFolder { .live() }

    func makeFirstTaskView(cwd: URL, prompt: String) -> NSView? {
        owner.firstTaskView(cwd: cwd, prompt: prompt)
    }

    var ghosttyTheme: ThemeInput { ThemeStore.shared.input }
    var ghosttyHasOwnTheme: Bool { GhosttyOwnTheme.isSet() }
    var selectedThemeName: String? { services.settings?.snapshot.root.value(at: TerminalThemeSetting.path)?.stringValue }
    var density: Density { DesignSettings.shared.density }

    func loadThemeChoices() async -> [ThemeChoice] {
        await Task.detached { ThemeChoice.loadCurated(resourcesDirectory: GhosttyRuntime.resourcesDirectory()) }.value
    }

    /// The last write `applyAppearance` started; each waits for the one
    /// before, so a revert never lands ahead of the try it undoes.
    private var lastWrite: Task<Void, Never>?

    /// Waits for every write `applyAppearance` started (tests).
    func flush() async {
        await lastWrite?.value
    }

    func applyAppearance(themeName: String?, density: Density) {
        guard let settings = services.settings else { return }
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            // Compare with the file, not `snapshot`: the watcher may not
            // have reloaded the previous write yet.
            let current = try? await settings.file.value(at: TerminalThemeSetting.path)?.stringValue
            // Both through the validated `setSetting`, as the Settings window
            // and the palette write them.
            if themeName != current {
                try? await settings.setSetting(at: TerminalThemeSetting.path, to: themeName.map(JSONValue.string), by: .user)
            }
            // Compact applies when the file has no density (`SettingsApplier`).
            let currentDensity = (try? await settings.file.value(at: ["appearance", "density"]))?
                .stringValue.flatMap(Density.init(rawValue:)) ?? .compact
            if density != currentDensity { try? await settings.setDensity(density) }
        }
    }

    func scanAgentProjects() async -> [AgentProject] {
        await Task.detached { RecentProjectScan.live().run() }.value
    }

    func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // A sheet on the onboarding window, so the step stays in front and one panel opens at a time.
        let response = await withCheckedContinuation { done in
            if let window = owner.controller?.window {
                panel.beginSheetModal(for: window) { done.resume(returning: $0) }
            } else {
                panel.begin { done.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    /// One workspace per folder, named after it, in the current window
    /// (a new one when none is open). They are created one after another so
    /// the sidebar keeps the list's order; any macOS privacy prompts for
    /// Desktop or Documents come now, together, as the step said.
    func openProjects(_ folders: [URL]) {
        guard let windows = services.windows else { return }
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        // Every folder counts as opening now, so chats picked meanwhile wait for it.
        let spawns = folders.map { ($0, folderSpawn($0)) }
        let logger = services.daemon.logger
        Task { [weak self] in
            for (folder, spawn) in spawns {
                do {
                    _ = try await windows.createWorkspace(spawn, into: target)
                } catch {
                    self?.folderFailed(folder, error, logger: logger)
                }
            }
        }
    }

    func detectBrowsers() async -> [BrowserSource] {
        await Task.detached {
            let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return BrowserSourceDetector(environment: environment).detect()
        }.value
    }

    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        let cache = services.cache!
        let destination = AppImportDestination(store: owner.importStore, bookmarks: services.importedBookmarkSink) { id in
            cache.history(for: BrowserProfileRecord.engineProfile(for: id) ?? .default)
        }
        let cef = cache.cef
        // One Keychain prompt per browser for cookies and passwords together; the keys go when the run ends.
        let keys = OneReadSafeStorage(SafeStorageKeys().live())
        let cookies = CookieImporter(destination: AppCookieDestination { writes, profile in try await cef.importCookies(writes, into: profile) },
                                     keys: keys)
        // Passwords only from profiles the user agreed to on the consent screen (the plan carries no others).
        var passwords: PasswordImporter?
        if plan.items.contains(where: { $0.kinds.contains(.passwords) }), await cef.canImportPasswords() {
            passwords = PasswordImporter(keys: keys, destination: AppPasswordDestination(available: true) { rows, profile in
                try await cef.importPasswords(rows, into: profile)
            }, primaryPassword: { profile in await FirefoxPrimaryPassword.prompt(profile) })
        }
        let importer = BrowserImporter(provisioning: AppBrowserProfileProvisioning(profiles: services.browserProfiles), store: owner.importStore,
                                       cookies: cookies, passwords: passwords)
        let summary = try await importer.run(plan, into: destination) { step in
            Task { @MainActor in progress(step) }
        }
        owner.cookiePrompt.importFinished(summary)
        return summary
    }

    func canImportPasswords() async -> Bool {
        await services.cache?.cef.canImportPasswords() ?? false
    }

    /// Touch ID, or the Mac's password where there is none. Only a Mac with
    /// no login password at all goes on without it; any other failure stops
    /// the import, since an "Always Allow" on the Keychain prompt means no
    /// prompt follows.
    func authorizePasswordRead(reason: String) async -> Bool {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            return unavailable?.domain == LAErrorDomain && unavailable?.code == LAError.Code.passcodeNotSet.rawValue
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    var defaultApps: any DefaultAppRegistering { owner.defaultApps }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Computer Use Setup's grants (`ComputerUseSetup`, the same state the
    /// palette action and Settings show). The step shows whenever Computer
    /// Use may run: off, it says so and Allow turns it on. A DEBUG launch
    /// with `CMUX_NEXT_ONBOARDING_COMPUTER_USE=mock` gets grants
    /// `debug.onboarding grant` flips instead.
    var computerUsePermissions: (any ComputerUsePermissionSource)? {
        // Turned off by policy (DisabledFeatures): no step and no prompts.
        services.registry.disabledFeatures.contains(.computerUse) ? nil : computerUseSource
    }

    private var resolvedComputerUseSource: (any ComputerUsePermissionSource)?
    private var computerUseSource: any ComputerUsePermissionSource {
        if let resolvedComputerUseSource { return resolvedComputerUseSource }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_ONBOARDING_COMPUTER_USE"] == "mock" {
            let mock = MockComputerUsePermissionSource(helperAppURL: URL(fileURLWithPath: "/Applications/cmux Computer Use.app"))
            resolvedComputerUseSource = mock
            return mock
        }
        #endif
        let source = AppComputerUsePermissionSource(setup: services.onboarding.computerUseSetup)
        resolvedComputerUseSource = source
        return source
    }

    var hasAccountsStep: Bool { true }

    func makeAccountsStepView() -> NSView? {
        NSHostingView(rootView: AccountsStepView(model: services.accounts.model, palette: .app))
    }

    /// The review tool's pick (DEBUG builds only): a Release first run
    /// always uses each screen's default. Picks live in the review file,
    /// never in cmux.json.
    func variantID(for step: OnboardingModel.Step) -> String? {
        #if DEBUG
        owner.galleryStore.pick(for: step)
        #else
        nil
        #endif
    }

    func setVariantID(_ id: String?, for step: OnboardingModel.Step) {
        owner.galleryStore.update { $0.picks[step.rawValue] = id }
    }

    func onboardingDidEnd(completed: Bool) {
        owner.didEnd(completed: completed)
    }

    func onboardingDidReach(_ step: OnboardingModel.Step, interacted: Bool) {
        owner.recordProgress(step, interacted: interacted)
    }

    func onboardingDidLeave(notNow: Bool) {
        if notNow { owner.recordNotNow() }
    }
}

import AppKit
import CmuxNextAgentActivity
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCookieImport
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextOnboarding
import CmuxNextSettings
import LocalAuthentication
import CmuxNextCompat

/// `OnboardingServices` over the app for the tool window: the importer
/// (cookies and passwords into each profile's Chromium store) and the
/// Computer Use helper's grants.
@MainActor
final class AppOnboardingServices: OnboardingServices {
    unowned let owner: OnboardingService
    var services: AppServices { owner.services }

    init(owner: OnboardingService) {
        self.owner = owner
    }

    /// Folder grants (Debug Settings `browserImport.folderGrant`).
    private let folderAccess = BrowserFolderAccess()

    /// None while `browser.import.enabled` is off: nothing reads another browser's folders.
    func detectBrowsers() async -> [BrowserSource] {
        guard services.browserImportEnabled else { return [] }
        return await folderAccess.detect()
    }
    func browsersAwaitingAccess() async -> [ImportBrowser] { await folderAccess.awaiting() }
    func accessFolder(for browser: ImportBrowser) -> URL? { folderAccess.folder(browser) }
    func requestFolderAccess(for browser: ImportBrowser) async -> Bool { await folderAccess.request(browser) }

    func importPasswordsFromCSV(into profile: String?) { try? PasswordCSVFiles(services: services).chooseImport(profile: profile ?? BrowserProfileRecord.defaultID) }

    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        // One Keychain prompt per browser for cookies and passwords together; the keys go when the run ends.
        try await runImport(plan, keys: OneReadSafeStorage(SafeStorageKeys().live()), progress: progress)
    }

    /// The import run with the caller's Keychain reads, so a job of several plans (the import
    /// cards' one plan per profile) asks macOS once per browser rather than once per plan.
    func runImport(_ plan: ImportPlan, keys: any SafeStorageKeyProviding,
                   progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        // `browser.import.enabled` off: a window or card still on screen starts no run.
        guard services.browserImportEnabled else { throw BrowserImportTurnedOff(BrowserImportOfferStrings.turnedOff) }
        let destination = SavingImportDestination.app(services, bookmarks: services.importedBookmarkSink)
        let cef = services.cache.cef
        let cookies = CookieImporter(destination: ChromiumCookieDestination { writes, profile in try await cef.importCookies(writes, into: profile) },
                                     keys: keys)
        // Passwords only from profiles the user agreed to on the consent screen (the plan carries no others).
        var passwords: PasswordImporter?
        // Sign-ins saved with another password are held for the toast's Replace when this fork can replace them (API 20).
        var hold: PasswordConflictHold?
        if plan.items.contains(where: { $0.kinds.contains(.passwords) }), await cef.canImportPasswords() {
            hold = cef.canReplacePasswords ? PasswordConflictHold { rows, profile in try await cef.replacePasswords(rows, in: profile) } : nil
            passwords = PasswordImporter(keys: keys, destination: AppPasswordDestination(available: true, hold: hold) { rows, profile in
                try await cef.importPasswords(rows, into: profile)
            }, primaryPassword: { profile in await FirefoxPrimaryPassword.prompt(profile) })
        }
        let importer = BrowserImporter(provisioning: AppBrowserProfileProvisioning(profiles: services.browserProfiles), store: owner.importStore,
                                       cookies: cookies, passwords: passwords)
        let summary: ImportSummary
        let endAccess = folderAccess.access(plan)
        defer { endAccess() }
        do {
            summary = try await importer.run(plan, into: destination) { step in
                Task { @MainActor in progress(step) }
            }
        } catch {
            hold?.release()
            throw error
        }
        owner.browserImportOffer.importFinished(summary)
        await owner.historySync.reconcile()
        ImportedTabsOpener.open(summary, services: services)
        if let engine = summary.searchEngine, let settings = services.settings { await BrowserOmnibarSetting.applyImported(engine.setting(builtIn: BrowserSearchEngine.templates), in: settings) }
        // The app window, not the tool window: closing that with Done would take the offer with it.
        let windows = services.windows
        if let hold { BrowserImportConflictOffer.offer(hold) { windows.active?.window ?? NSApp.mainWindow } }
        return summary
    }

    func canImportPasswords() async -> Bool { await services.cache.cef.canImportPasswords() }

    func importTargets() async -> [ImportTargetChoice] { services.browserProfiles.ordered.map { ImportTargetChoice(id: $0.id, name: $0.name) } }
    func earlierImportTargets() async -> [String: String] { await owner.importStore.movedSources() }

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

    func openExternal(_ url: URL) { NSWorkspace.shared.openInBackground(url) }
    func importFromFiles(into profile: String?) { BrowserFileImport(services: services).run(profile: profile ?? BrowserProfileRecord.defaultID) }

    /// Computer Use Setup's grants (`ComputerUseSetup`, the same state the
    /// palette action and Settings show). The step shows whenever Computer
    /// Use may run: off, it says so and Allow turns it on. A DEBUG launch
    /// with `CMUX_NEXT_ONBOARDING_COMPUTER_USE=mock` gets grants
    /// `debug.onboarding grant` flips instead.
    var computerUsePermissions: (any ComputerUsePermissionSource)? {
        // Turned off by policy (DisabledFeatures): no step and no prompts.
        services.registry.disabledFeatures.contains(.computerUse) ? nil : computerUseSource
    }

    private lazy var computerUseSource: any ComputerUsePermissionSource = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_ONBOARDING_COMPUTER_USE"] == "mock" {
            // The NIGHTLY's helper path, so the window and panel show its icon and name when it is installed.
            let helper = CuaHelperIdentity.installedCandidates(isDevBuild: true).first
            return MockComputerUsePermissionSource(helperAppURL: helper ?? URL(fileURLWithPath: "/Applications/cmux Computer Use.app"))
        }
        #endif
        return AppComputerUsePermissionSource(setup: services.onboarding.computerUseSetup)
    }()
}

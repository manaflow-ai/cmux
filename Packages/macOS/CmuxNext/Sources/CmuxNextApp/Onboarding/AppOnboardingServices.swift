import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCookieImport
import CmuxNextDesign
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

    /// The folder grants (Debug Settings `browserImport.folderGrant`, on by
    /// default); nil reads every browser's folder on Find Browsers.
    private var grants: BrowserFolderGrants? {
        guard BrowserImportTunables.folderGrant.value else { return nil }
        let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return BrowserFolderGrants(environment: environment, store: UserDefaultsBrowserFolderGrantStore())
    }

    func detectBrowsers() async -> [BrowserSource] {
        let grants = grants
        return await Task.detached {
            if let grants { return grants.detect() }
            let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return BrowserSourceDetector(environment: environment).detect()
        }.value
    }

    func browsersAwaitingAccess() async -> [ImportBrowser] {
        guard let grants else { return [] }
        return await Task.detached { grants.awaiting() }.value
    }

    func accessFolder(for browser: ImportBrowser) -> URL? { grants?.folder(browser) }

    /// The open panel at `browser`'s data folder, prompt Allow Access; only
    /// that folder is accepted and kept (`BrowserFolderGrants`).
    func requestFolderAccess(for browser: ImportBrowser) async -> Bool {
        guard let grants else { return false }
        let folder = grants.folder(browser)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = BrowserFolderAccessStrings.prompt
        panel.message = BrowserFolderAccessStrings.message(browser.displayName)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.browserImport.folderAccess")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let picked = panel.url else { return false }
        return (try? grants.grant(picked, for: browser)) != nil
    }

    func importPasswordsFromCSV(into profile: String?) {
        try? PasswordCSVFiles(services: services).chooseImport(profile: profile ?? BrowserProfileRecord.defaultID)
    }

    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        let cache = services.cache
        let destination = AppImportDestination(store: owner.importStore, bookmarks: services.importedBookmarkSink) { id in
            cache.history(for: BrowserProfileRecord.engineProfile(for: id) ?? .default)
        }
        let cef = cache.cef
        // One Keychain prompt per browser for cookies and passwords together; the keys go when the run ends.
        let keys = OneReadSafeStorage(SafeStorageKeys().live())
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
        // The granted folders stay in scope for the run (one per browser in the plan).
        let scoped = grants.map { grants in Array(Set(plan.items.map(\.profile.browser))).compactMap(grants.grantedFolder) } ?? []
        let started = scoped.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            summary = try await importer.run(plan, into: destination) { step in
                Task { @MainActor in progress(step) }
            }
        } catch {
            hold?.release()
            throw error
        }
        owner.browserImportOffer.importFinished(summary)
        // The app window, not the tool window: closing that with Done would take the offer with it.
        let windows = services.windows
        if let hold { BrowserImportConflictOffer.offer(hold) { windows.active?.window ?? NSApp.mainWindow } }
        return summary
    }

    func canImportPasswords() async -> Bool {
        await services.cache.cef.canImportPasswords()
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

    func openExternal(_ url: URL) {
        NSWorkspace.shared.openInBackground(url)
    }

    func importFromFiles(into profile: String?) {
        BrowserFileImport(services: services).run(profile: profile ?? BrowserProfileRecord.defaultID)
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
}

import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import LocalAuthentication

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

    func detectBrowsers() async -> [BrowserSource] {
        await Task.detached {
            let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return BrowserSourceDetector(environment: environment).detect()
        }.value
    }

    func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        let cache = services.cache
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
        owner.browserImportOffer.importFinished(summary)
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
}

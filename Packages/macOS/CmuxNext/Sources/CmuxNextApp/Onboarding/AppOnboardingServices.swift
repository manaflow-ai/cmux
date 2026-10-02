import AppKit
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
    private var services: AppServices { owner.services }

    init(owner: OnboardingService) {
        self.owner = owner
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
            if themeName != current {
                if let themeName {
                    try? await settings.set(.string(themeName), at: TerminalThemeSetting.path)
                } else {
                    try? await settings.file.remove(TerminalThemeSetting.path)
                }
            }
            // Compact applies when the file has no density (`SettingsApplier`).
            let currentDensity = (try? await settings.file.value(at: ["appearance", "density"]))?
                .stringValue.flatMap(Density.init(rawValue:)) ?? .compact
            if density != currentDensity { try? await settings.setDensity(density) }
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
            })
        }
        let importer = BrowserImporter(provisioning: AppBrowserProfileProvisioning(profiles: services.browserProfiles), store: owner.importStore,
                                       cookies: cookies, passwords: passwords)
        return try await importer.run(plan, into: destination) { step in
            Task { @MainActor in progress(step) }
        }
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
        owner.markDone(completed: completed)
    }
}

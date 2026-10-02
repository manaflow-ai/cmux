import AppKit
import CmuxNextAccounts
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextTerminal
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
    var selectedThemeName: String? { services.settings?.snapshot.root.value(at: TerminalThemeSetting.path)?.stringValue }
    var density: Density { DesignSettings.shared.density }

    func loadThemeChoices() async -> [ThemeChoice] {
        await Task.detached { ThemeChoice.loadCurated(resourcesDirectory: GhosttyRuntime.resourcesDirectory()) }.value
    }

    func applyAppearance(themeName: String?, density: Density) {
        guard let settings = services.settings else { return }
        let current = selectedThemeName
        Task {
            if themeName != current {
                if let themeName {
                    try? await settings.set(.string(themeName), at: TerminalThemeSetting.path)
                } else {
                    try? await settings.file.remove(TerminalThemeSetting.path)
                }
            }
            if density != DesignSettings.shared.density { try? await settings.setDensity(density) }
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
        let cookies = CookieImporter(destination: AppCookieDestination { writes, profile in try await cef.importCookies(writes, into: profile) },
                                     keys: SafeStorageKeys().live())
        let importer = BrowserImporter(provisioning: AppBrowserProfileProvisioning(profiles: services.browserProfiles), store: owner.importStore,
                                       cookies: cookies)
        return try await importer.run(plan, into: destination) { step in
            Task { @MainActor in progress(step) }
        }
    }

    var defaultApps: any DefaultAppRegistering { owner.defaultApps }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var hasAccountsStep: Bool { true }

    func makeAccountsStepView() -> NSView? {
        NSHostingView(rootView: AccountsStepView(model: services.accounts.model, palette: .app))
    }

    /// cmux.json `debug.onboardingVariants.<step>` (set from the gallery).
    static func variantPath(_ step: OnboardingModel.Step) -> [String] { ["debug", "onboardingVariants", step.rawValue] }

    /// DEBUG builds only: a Release first run always uses each screen's
    /// default (a gallery pick in a tagged build must not change it).
    func variantID(for step: OnboardingModel.Step) -> String? {
        #if DEBUG
        services.settings?.snapshot.root.value(at: Self.variantPath(step))?.stringValue
        #else
        nil
        #endif
    }

    func setVariantID(_ id: String?, for step: OnboardingModel.Step) {
        guard let settings = services.settings else { return }
        let path = Self.variantPath(step)
        // task-owner: one cmux.json write
        Task {
            if let id { try? await settings.set(.string(id), at: path) } else { try? await settings.file.remove(path) }
        }
    }

    func onboardingDidEnd(completed: Bool) {
        owner.markDone(completed: completed)
    }
}

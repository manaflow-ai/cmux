import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextTerminal

/// `OnboardingServices` over the app: cmux.json for theme and density, the
/// importer and omnibar history, browser tabs, the action registry's live
/// shortcuts, and the default-app registry (mocked in test launches).
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
        let destination = AppImportDestination(store: owner.importStore) { id in
            cache.history(for: BrowserProfileRecord.engineProfile(for: id) ?? .default)
        }
        let importer = BrowserImporter(provisioning: AppBrowserProfileProvisioning(profiles: services.browserProfiles), store: owner.importStore)
        return try await importer.run(plan, into: destination) { step in
            Task { @MainActor in progress(step) }
        }
    }

    func installExtension(_ item: ImportedExtension) {
        // Chromium installs from the store page ("Add to Chrome").
        focusedPane()?.newBrowserTab(url: item.webStoreURL, engine: BrowserEngineTag.cef.rawValue)
    }

    func openTabs(_ tabs: [ImportedTab]) {
        guard let pane = focusedPane() else { return }
        for (index, tab) in tabs.enumerated() { pane.newBrowserTab(url: tab.url, background: index > 0) }
    }

    var browserProfilesAvailable: Bool { true }
    var defaultApps: any DefaultAppRegistering { owner.defaultApps }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func shortcutDisplay(for actionID: String) -> String? {
        services.registry.effectiveShortcut(for: ActionID(rawValue: actionID))?.displayString
    }

    func onboardingDidEnd(completed: Bool) {
        owner.markDone(completed: completed)
    }

    private func focusedPane() -> PaneController? {
        services.windows.active?.focusedPane
    }
}

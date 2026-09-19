import AppKit
import CmuxBrowser
import Foundation
import Observation

/// Owns admission, asynchronous discovery, and presentation for browser imports.
@MainActor
@Observable
final class BrowserDataImportCoordinator {
    private let browserDetection: BrowserInstalledBrowserDetectionService
    @ObservationIgnored private var presentationTask: Task<Void, Never>?

    init(browserDetection: BrowserInstalledBrowserDetectionService = .init()) {
        self.browserDetection = browserDetection
    }

    deinit { presentationTask?.cancel() }

    func presentImportDialog(
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) {
        guard presentationTask == nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            await self?.presentImportDialogAsync(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: defaultScope
            )
        }
    }

    func detectInstalledBrowsers() async -> [InstalledBrowserCandidate] {
        await browserDetection.detectInstalledBrowsers()
    }

    struct ImportSelection {
        let browser: InstalledBrowserCandidate
        let executionPlan: BrowserImportExecutionPlan
        let scope: BrowserImportScope
        let domainFilters: [String]
    }

    private func presentImportDialogAsync(
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) async {
        defer {
            presentationTask = nil
        }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let fixtureBrowsers = BrowserImportUITestFixtureLoader.browsers(from: environment)
        let fixtureDestinationProfiles = BrowserImportUITestFixtureLoader.destinationProfiles(from: environment)
#else
        let fixtureBrowsers: [InstalledBrowserCandidate]? = nil
        let fixtureDestinationProfiles: [BrowserProfileDefinition]? = nil
#endif
        let browsers: [InstalledBrowserCandidate]
        if let fixtureBrowsers {
            browsers = fixtureBrowsers
        } else {
            browsers = await browserDetection.detectInstalledBrowsers()
        }
        guard !Task.isCancelled else { return }
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.noBrowsers.title",
                defaultValue: "No importable browsers found"
            )
            alert.informativeText = String(
                localized: "browser.import.noBrowsers.message",
                defaultValue: "cmux could not find browser profiles to import from on this Mac."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(
            browsers: browsers,
            destinationProfiles: fixtureDestinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        ) else {
            return
        }

#if DEBUG
        if captureSelectionIfRequested(selection, destinationProfiles: fixtureDestinationProfiles) {
            return
        }
#endif
        let realizedPlan: RealizedBrowserImportExecutionPlan
        do {
            realizedPlan = try BrowserImportPlanResolver.realize(plan: selection.executionPlan)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.error.title",
                defaultValue: "Import could not start"
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }

        let progressWindow = showProgressWindow(
            title: String(
                localized: "browser.import.progress.title",
                defaultValue: "Importing Browser Data"
            ),
            message: String(
                format: String(
                    localized: "browser.import.progress.message",
                    defaultValue: "Importing %@ from %@…"
                ),
                selection.scope.displayName.lowercased(),
                selection.browser.displayName
            )
        )

        let outcome = await Task.detached(priority: .userInitiated) {
            await BrowserDataImporter.importData(
                from: selection.browser,
                plan: realizedPlan,
                scope: selection.scope,
                domainFilters: selection.domainFilters
            )
        }.value
        hideProgressWindow(progressWindow)
        presentOutcome(outcome)
    }
}

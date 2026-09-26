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

    var isPresentationAvailable: Bool { presentationTask == nil }

    init(browserDetection: BrowserInstalledBrowserDetectionService = .init()) {
        self.browserDetection = browserDetection
    }

    deinit { presentationTask?.cancel() }

    @discardableResult
    func presentImportDialog(
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) -> Bool {
        guard presentationTask == nil else { return false }
        presentationTask = Task { @MainActor [weak self] in
            await self?.presentImportDialogAsync(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: defaultScope
            )
        }
        return true
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

#if DEBUG
    private struct CapturedImportSelection: Encodable {
        struct Entry: Encodable {
            let sourceProfiles: [String]
            let destinationKind: String
            let destinationName: String
        }

        let browserName: String
        let mode: String
        let scope: String
        let domainFilters: [String]
        let entries: [Entry]
    }

    private func captureSelectionIfRequested(
        _ selection: ImportSelection,
        destinationProfiles: [BrowserProfileDefinition]?
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] == "capture-only" else { return false }
        guard let path = environment["CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"], !path.isEmpty else {
            return true
        }

        let availableDestinationProfiles = destinationProfiles ?? BrowserProfileStore.shared.profiles
        let payload = CapturedImportSelection(
            browserName: selection.browser.displayName,
            mode: captureModeName(selection.executionPlan.mode),
            scope: selection.scope.rawValue,
            domainFilters: selection.domainFilters,
            entries: selection.executionPlan.entries.map { entry in
                let destinationKind: String
                let destinationName: String
                switch entry.destination {
                case .existing(let id):
                    destinationKind = "existing"
                    destinationName = availableDestinationProfiles.first(where: { $0.id == id })?.displayName
                        ?? BrowserProfileStore.shared.displayName(for: id)
                case .createNamed(let name):
                    destinationKind = "create"
                    destinationName = name
                }
                return CapturedImportSelection.Entry(
                    sourceProfiles: entry.sourceProfiles.map(\.displayName),
                    destinationKind: destinationKind,
                    destinationName: destinationName
                )
            }
        )

        guard let data = try? JSONEncoder().encode(payload) else { return true }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: url)
        return true
    }

    private func captureModeName(_ mode: BrowserImportDestinationMode) -> String {
        switch mode {
        case .singleDestination:
            return "singleDestination"
        case .separateProfiles:
            return "separateProfiles"
        case .mergeIntoOne:
            return "mergeIntoOne"
        }
    }
#endif

}

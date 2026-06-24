public import AppKit
public import CmuxBrowser
public import Foundation
import Observation

/// Drives the browser-data import user flow: detects installed browsers, runs
/// the modal ``BrowserImportWizardWindowController``, realizes the chosen plan
/// against the cmux profile store, then performs the import on a background task
/// while showing progress and result UI.
///
/// The destination profile store and the import persistence sink are supplied by
/// the app on the ``shared`` instance through
/// ``configure(profileResolver:importPersistence:)`` so this package never
/// references the app's concrete `BrowserProfileStore` or its WebKit/filesystem
/// persistence. The ``shared`` static-let seam is a deliberate interim until the
/// import flow is reachable through full constructor injection from the
/// composition root.
@MainActor
@Observable
public final class BrowserDataImportCoordinator {
    /// The shared coordinator the app's import entrypoints invoke.
    public static let shared = BrowserDataImportCoordinator()

    /// The destination profile store the import flow reads and writes, supplied
    /// by the app via ``configure(profileResolver:importPersistence:)``. Until
    /// the app wires it, lookups fall back to an empty resolver (only reached by
    /// DEBUG wizard-construction probes that pass destination profiles
    /// explicitly).
    private var configuredProfileResolver: (any BrowserImportProfileResolving)?

    /// The persistence sink a ``BrowserDataImporter`` writes parsed records into,
    /// supplied by the app via ``configure(profileResolver:importPersistence:)``.
    private var configuredImportPersistence: (any BrowserImportPersisting)?

    /// Wires the app's profile store and import persistence onto the shared
    /// coordinator instance. Call once during app startup before any import
    /// entrypoint runs.
    /// - Parameters:
    ///   - profileResolver: The destination profile store.
    ///   - importPersistence: The persistence sink imports write into.
    public func configure(
        profileResolver: any BrowserImportProfileResolving,
        importPersistence: any BrowserImportPersisting
    ) {
        configuredProfileResolver = profileResolver
        configuredImportPersistence = importPersistence
    }

    private var importInProgress = false

    /// Held detector instance; the coordinator detects and summarizes installed
    /// browsers through this rather than the former `BrowserInstalledBrowserDetector`
    /// static namespace.
    private let installedBrowserDetector = BrowserInstalledBrowserDetector()

    private init() {}

    /// The app-supplied profile store, or an empty fallback when ``configure``
    /// has not run (only reached by DEBUG wizard-construction probes that pass
    /// destination profiles explicitly).
    private var profileResolver: any BrowserImportProfileResolving {
        configuredProfileResolver ?? EmptyBrowserImportProfileResolving()
    }

    /// The app-supplied persistence sink, or a no-op fallback when ``configure``
    /// has not run. The fallback keeps the import flow's control path identical
    /// to before extraction (the importer is always created and run); it imports
    /// nothing because no destination store is wired.
    private var importPersistence: any BrowserImportPersisting {
        configuredImportPersistence ?? EmptyBrowserImportPersisting()
    }

    /// Presents the import wizard, optionally pre-selecting a destination profile
    /// and data scope.
    /// - Parameters:
    ///   - defaultDestinationProfileID: Pre-selected destination profile, if any.
    ///   - defaultScope: Pre-selected data scope, if any.
    public func presentImportDialog(
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) {
        presentImportDialog(
            prefilledBrowsers: nil,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        )
    }

    private func presentImportDialog(
        prefilledBrowsers: [InstalledBrowserCandidate]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) {
        guard !importInProgress else { return }
#if DEBUG
        let fixtureLoader = BrowserImportUITestFixtureLoader(
            environment: ProcessInfo.processInfo.environment
        )
        let fixtureBrowsers = fixtureLoader.browsers()
        let fixtureDestinationProfiles = fixtureLoader.destinationProfiles()
        let browsers = prefilledBrowsers ?? fixtureBrowsers ?? installedBrowserDetector.detectInstalledBrowsers()
#else
        let fixtureDestinationProfiles: [BrowserProfileDefinition]? = nil
        let browsers = prefilledBrowsers ?? installedBrowserDetector.detectInstalledBrowsers()
#endif
        guard !browsers.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.noBrowsers.title",
                defaultValue: "No importable browsers found",
                bundle: .module
            )
            alert.informativeText = String(
                localized: "browser.import.noBrowsers.message",
                defaultValue: "cmux could not find browser profiles to import from on this Mac.",
                bundle: .module
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module))
            alert.runModal()
            return
        }

        guard let selection = promptForSelection(
            browsers: browsers,
            destinationProfiles: fixtureDestinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope
        ) else { return }

#if DEBUG
        if captureSelectionIfRequested(selection, destinationProfiles: fixtureDestinationProfiles) {
            return
        }
#endif
        let realizedPlan: RealizedBrowserImportExecutionPlan
        do {
            realizedPlan = try RealizedBrowserImportExecutionPlan.realized(
                from: selection.executionPlan,
                profileResolver: profileResolver
            )
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "browser.import.error.title",
                defaultValue: "Import could not start",
                bundle: .module
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module))
            alert.runModal()
            return
        }
        importInProgress = true

        let progressWindow = showProgressWindow(
            title: String(
                localized: "browser.import.progress.title",
                defaultValue: "Importing Browser Data",
                bundle: .module
            ),
            message: String(
                format: String(
                    localized: "browser.import.progress.message",
                    defaultValue: "Importing %@ from %@…",
                    bundle: .module
                ),
                selection.scope.displayName.lowercased(),
                selection.browser.displayName
            )
        )

        let persistence = importPersistence
        Task.detached(priority: .userInitiated) {
            let importer = BrowserDataImporter(persistence: persistence)
            let outcome = await importer.importData(
                from: selection.browser,
                plan: realizedPlan,
                scope: selection.scope,
                domainFilters: selection.domainFilters
            )

            await MainActor.run {
                self.hideProgressWindow(progressWindow)
                self.presentOutcome(outcome)
                self.importInProgress = false
            }
        }
    }

    private func promptForSelection(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?
    ) -> BrowserImportSelection? {
        guard !browsers.isEmpty else { return nil }
        let wizard = BrowserImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope,
            profileResolver: profileResolver
        )
        return wizard.runModal()
    }

#if DEBUG
    /// Builds the import wizard's panel window for UI-test inspection without
    /// running it modally.
    public func debugMakeImportWizardWindow(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]? = nil,
        defaultDestinationProfileID: UUID? = nil,
        defaultScope: BrowserImportScope? = nil
    ) -> NSWindow {
        let wizard = BrowserImportWizardWindowController(
            browsers: browsers,
            destinationProfiles: destinationProfiles,
            defaultDestinationProfileID: defaultDestinationProfileID,
            defaultScope: defaultScope,
            profileResolver: profileResolver
        )
        return wizard.debugPanelWindow
    }
#endif

#if DEBUG
    private func captureSelectionIfRequested(
        _ selection: BrowserImportSelection,
        destinationProfiles: [BrowserProfileDefinition]?
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] == "capture-only" else { return false }
        guard let path = environment["CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"], !path.isEmpty else {
            return true
        }

        let availableDestinationProfiles = destinationProfiles ?? profileResolver.profiles
        let payload = CapturedBrowserImportSelection(
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
                        ?? profileResolver.displayName(for: id)
                case .createNamed(let name):
                    destinationKind = "create"
                    destinationName = name
                }
                return CapturedBrowserImportSelection.Entry(
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

    private func showProgressWindow(title: String, message: String) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 122))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let titleLabel = NSTextField(labelWithString: message)
        titleLabel.frame = NSRect(x: 52, y: 56, width: 340, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(titleLabel)

        let subtitleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.progress.subtitle",
                defaultValue: "This can take a few seconds for large profiles.",
                bundle: .module
            )
        )
        subtitleLabel.frame = NSRect(x: 52, y: 34, width: 340, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        content.addSubview(subtitleLabel)

        window.contentView = content

        if let keyWindow = NSApp.keyWindow {
            keyWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        return window
    }

    private func hideProgressWindow(_ window: NSWindow) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    private func presentOutcome(_ outcome: BrowserImportOutcome) {
        let lines = outcome.formattedLines
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.import.complete.title",
            defaultValue: "Browser data import complete",
            bundle: .module
        )
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module))
        alert.runModal()
    }
}

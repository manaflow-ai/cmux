import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextHangReports
import CmuxNextSettings
import CmuxNextSidebar
import os

/// The app side of opt-in hang reports (plans/cmux-next/hang-reports-DESIGN.md): follows
/// `diagnostics.hangReports`, turns the MetricKit subscription and the watchdog sink on and off,
/// asks once on NIGHTLY through the sidebar's notice card, and opens View Hang Report.
///
/// Only NIGHTLY builds send (`CrashReportingPolicy.Channel.nightly`); a managed `DisableTelemetry`
/// turns it off for good. A DEV build sends only with `CMUX_NEXT_DEV_HANG_REPORTS=1`, to the
/// address in `CMUX_NEXT_HANG_REPORTS_URL` (an end-to-end check against a local server).
/// No timers: work happens on a setting change, a MetricKit delivery and the launch.
@MainActor
final class HangReportsController {
    static let askedKey = "cmux.next.hangReports.asked"
    static let devOptInKey = "CMUX_NEXT_DEV_HANG_REPORTS"
    static let devEndpointKey = "CMUX_NEXT_HANG_REPORTS_URL"

    let service: HangReportService
    /// This build may send at all (NIGHTLY, or a DEV build opted in); a managed block is read later.
    private let mayReport: Bool
    /// Whether a managed profile forces `DisableTelemetry` (read off the main thread at start).
    private let managedDisables: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hang-reports")
    private var subscriber: MetricKitSubscriber?
    private var settingsObservation: Task<Void, Never>?
    private var launchedOnce = false

    init(service: HangReportService, mayReport: Bool, managedDisables: @escaping @Sendable () -> Bool,
         defaults: UserDefaults = .standard) {
        self.service = service
        self.mayReport = mayReport
        self.managedDisables = managedDisables
        self.defaults = defaults
    }

    /// The controller for this launch: the service over this build's folder, the real transport,
    /// classifier and dyld resolver, and the app's own envelope values.
    static func forThisLaunch(policy: CrashReportingPolicy, folder: URL, counts: @escaping @Sendable () async -> CoarseCounts,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> HangReportsController {
        let devOptIn = policy.channel == .dev && environment[devOptInKey] == "1"
        let mayReport = (policy.channel == .nightly || devOptIn) && environment["XCTestConfigurationFilePath"] == nil
        let endpoint = devOptIn ? environment[devEndpointKey] ?? URLSessionHangReportTransport.defaultEndpoint
            : URLSessionHangReportTransport.defaultEndpoint
        let terms = ImageClassifier.personalTerms()
        let resolver = DyldImageResolver()
        let builder = HangReportBuilder(classifier: ImageClassifier(appBundlePath: Bundle.main.bundlePath, forbiddenTerms: terms),
                                        resolver: resolver)
        let collector = HangReportCollector(resolve: { builder.frames(addresses: $0) })
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let service = HangReportService(
            store: HangReportStore(directory: folder), transport: URLSessionHangReportTransport(endpoint: endpoint),
            builder: builder, scanner: PrivacyLeakScanner(forbiddenTerms: terms), identity: InstallIdentity(),
            collector: collector,
            environment: HangReportService.Environment(
                app: HangReport.App(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                    build: info["CFBundleVersion"] as? String ?? "0",
                                    channel: policy.channel?.rawValue ?? "dev"),
                os: HangReport.OS(version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                hardware: .current(), counts: counts))
        let managed = ManagedPreferenceLocation.defaultReader(environment: environment)
        return HangReportsController(service: service, mayReport: mayReport, managedDisables: {
            managed.read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true
        })
    }

    /// The watchdog sink (the app chains it after the lag-spike reporter).
    var collector: HangReportCollector { service.collector }

    /// Follows the setting from the first load on; asks once (NIGHTLY, setting off) after
    /// `firstWindow` resolves.
    func start(settings: SettingsController, asks: SidebarAsks, firstWindow: @escaping @MainActor () async -> Void) {
        guard mayReport else { return }
        let managedDisables = managedDisables
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            guard await Task.detached(priority: .utility, operation: { !managedDisables() }).value else { return }
            var asked = false
            for await on in ObservationStream({ settings.snapshot.hangReports }) {
                guard let self else { return }
                await apply(on)
                if !on, !asked, !defaults.bool(forKey: Self.askedKey) {
                    asked = true
                    await firstWindow()
                    // task-owner: one question; it ends when the person answers.
                    Task { await self.ask(asks: asks, settings: settings) }
                }
            }
        }
    }

    /// Quitting: the watchdog's findings wait on disk for the next launch's report.
    func applicationWillTerminate() {
        service.saveForNextLaunch()
    }

    /// View Hang Report: the last report sent, else a preview; opened in a cmux file tab.
    func viewReport(open: @escaping @MainActor (URL) -> Void) {
        let service = service
        // task-owner: one read and open; nothing to cancel.
        Task {
            guard let url = await service.viewableReport() else { return }
            open(url)
        }
    }

    private func apply(_ on: Bool) async {
        await service.setEnabled(on)
        if on {
            if subscriber == nil {
                let service = service
                let subscriber = MetricKitSubscriber { input in
                    // task-owner: one delivery handed to the service actor.
                    Task { await service.receive(input) }
                }
                subscriber.start()
                self.subscriber = subscriber
            }
            if !launchedOnce {
                launchedOnce = true
                await service.launched()
            }
        } else {
            subscriber?.stop()
            subscriber = nil
        }
    }

    /// The one-time question on the sidebar's notice card (no dialog). Any answer, the x
    /// included, means asked; only Send Hang Reports writes the setting (as the person).
    private func ask(asks: SidebarAsks, settings: SettingsController) async {
        guard !defaults.bool(forKey: Self.askedKey), !settings.snapshot.hangReports else { return }
        let yes = await asks.ask(HangReportsStrings.askTitle, detail: HangReportsStrings.askDetail, symbol: "gauge.with.dots.needle.33percent",
                                 yes: HangReportsStrings.askYes, no: HangReportsStrings.askNo)
        defaults.set(true, forKey: Self.askedKey)
        guard yes, let descriptor = SettingsSchema.descriptor(for: HangReportsSetting.path) else { return }
        do { try await settings.setSetting(descriptor, to: .bool(true), by: .user) } catch {
            logger.error("diagnostics.hangReports not written: \(String(describing: error), privacy: .public)")
        }
    }
}

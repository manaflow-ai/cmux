import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextHangReports
import CmuxNextInput
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextSignposts
import CmuxNextWakeups
import os

/// This Mac's personal terms (``ImageClassifier/personalTerms()``: NSFullUserName is an
/// OpenDirectory lookup, slow on a directory-bound Mac). A lazy global, computed once at its first
/// read, which is a name check on the collector's utility task or a scan on the service actor,
/// never the main thread at launch.
private nonisolated let personalTermsOfThisMac = ImageClassifier.personalTerms()

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
    /// This Mac's consent record: the time of the person's own yes (the card's Send Hang Reports,
    /// or a `SettingWriter.user` write of the setting: the Settings switch, Toggle Setting, a CLI
    /// call the confirmation sheet approved). Turning reports off removes it. The synced
    /// cmux-next.json alone never sends.
    static let consentKey = "cmux.next.hangReports.consentedAt"
    static let devOptInKey = "CMUX_NEXT_DEV_HANG_REPORTS"
    static let devEndpointKey = "CMUX_NEXT_HANG_REPORTS_URL"

    /// Nil on a build that never sends (Release, RC, DEV without the opt-in, tests): nothing is
    /// built, read or subscribed there.
    let service: HangReportService?
    /// Feeds the service's main-thread ledger the activation notices and input (nil where the
    /// builder's wire schema does not carry active time).
    private let activityFeed: MainThreadActivityFeed?
    /// Samples `memory.hidden_workspace_kib` at workspace switches, resign-active and report triggers (task 061),
    /// in every build: the histogram is local until a report sends it.
    private let memory: HiddenWorkspaceMemory?
    /// The app resigning active: a ``memory`` sample.
    private let memoryResignActive: EventSubscription?
    /// Whether a managed profile forces `DisableTelemetry` (read off the main thread at start).
    private let managedDisables: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hang-reports")
    private var subscriber: MetricKitSubscriber?
    private var settingsObservation: Task<Void, Never>?
    private var launchedOnce = false
    /// The card kinds put up this launch (each at most once): an invitation answered Not Now still
    /// lets a later switch-on in the same launch get its confirm card.
    private var askedThisLaunch: Set<HangReportAskPolicy.Decision> = []

    init(service: HangReportService?, managedDisables: @escaping @Sendable () -> Bool, defaults: UserDefaults = .standard,
         activityFeed: MainThreadActivityFeed? = nil, memory: HiddenWorkspaceMemory? = nil, events: AppEvents? = nil) {
        self.service = service
        self.activityFeed = activityFeed
        self.memory = memory
        memoryResignActive = memory.flatMap { memory in
            events?.subscribe(NSApplication.didResignActiveNotification, owner: "HiddenWorkspaceMemory") { [weak memory] in
                memory?.note(.resignActive)
            }
        }
        self.managedDisables = managedDisables
        self.defaults = defaults
    }

    /// The controller for this launch: the service over this build's folder, the real transport,
    /// classifier and dyld resolver, the app's own envelope values, and (when the wire schema carries
    /// them) the active time and `watchdog`'s main-turn and input-queueing histograms. `memory` samples at the
    /// report triggers too, and runs where nothing is sent.
    static func forThisLaunch(policy: CrashReportingPolicy, folder: URL, counts: @escaping @Sendable () async -> CoarseCounts,
                              watchdog: MainThreadWatchdog, input: any InputObserving, events: AppEvents, memory: HiddenWorkspaceMemory,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> HangReportsController {
        let devOptIn = policy.channel == .dev && environment[devOptInKey] == "1"
        let mayReport = (policy.channel == .nightly || devOptIn) && !CrashReportingPolicy.isTestProcess(environment)
        let managed = ManagedPreferenceLocation.defaultReader(environment: environment)
        let managedDisables: @Sendable () -> Bool = {
            managed.read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true
        }
        guard mayReport else { return HangReportsController(service: nil, managedDisables: managedDisables, memory: memory, events: events) }
        let endpoint = devOptIn ? environment[devEndpointKey] ?? URLSessionHangReportTransport.defaultEndpoint
            : URLSessionHangReportTransport.defaultEndpoint
        // A managed block, or this Mac's consent record removed, while cmux runs: the next trigger
        // turns reports off and drops what was recorded. UserDefaults is thread-safe; the record is
        // read in the app's own domain.
        let service = HangReportService.forThisApp(
            folder: folder, endpoint: endpoint, channel: policy.channel?.rawValue ?? "dev", personalTerms: personalTermsOfThisMac,
            counts: counts, stillAllowed: { [key = Self.consentKey] in !managedDisables() && UserDefaults.standard.object(forKey: key) is Date },
            mainThreadHistograms: { [watchdog] in
                MainThreadReportLedger.Histograms(edgesNanos: MainTurnHistogram.edgesNanos, turnCounts: watchdog.turnHistogram.snapshot().counts,
                                                  inputQueueingCounts: watchdog.inputQueueHistogram.snapshot().counts)
            })
        let feed = service.mainThreadLedger.map {
            MainThreadActivityFeed(ledger: $0, input: input, events: events, isActive: NSApp?.isActive ?? false)
        }
        return HangReportsController(service: service, managedDisables: managedDisables, activityFeed: feed, memory: memory, events: events)
    }

    /// A window showed a workspace and hid the one it showed: a memory per hidden workspace sample (task 061).
    func workspaceDidShow() {
        memory?.note(.workspaceSwitch)
    }

    /// The watchdog sink (the app chains it after the lag-spike reporter); nil where nothing is sent.
    var collector: HangReportCollector? { service?.collector }

    /// Whether this build can send hang reports at all.
    var isAvailable: Bool { service != nil }

    /// `debug.shipping_mode`'s hang reports (``ShippingModeReport/HangReports``) with the setting's value now.
    func shippingModeState(setting: Bool?) async -> ShippingModeReport.HangReports {
        let decision = isAvailable ? setting.map { String(describing: Self.decision(defaults: defaults, settingOn: $0)) } : nil
        return ShippingModeReport.HangReports(available: isAvailable, setting: setting, decision: decision,
                                              enabled: await service?.isEnabled ?? false)
    }

    /// Follows the setting from the first load on (``HangReportAskPolicy``): sends only with this
    /// Mac's consent record; otherwise shows the confirm or the one-time invitation card after
    /// `firstWindow` resolves. A managed `DisableTelemetry` turns everything off and clears what
    /// an earlier opted-in period left (read once per launch).
    func start(settings: SettingsController, asks: SidebarAsks, firstWindow: @escaping @MainActor () async -> Void) {
        guard service != nil else { return }
        settings.userWillWrite = { [defaults] descriptor, value in
            Self.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        let managedDisables = managedDisables
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            guard await Task.detached(priority: Task.currentPriority, operation: { !managedDisables() }).value else {
                await self?.apply(false, settingOn: false)
                return
            }
            for await on in ObservationStream({ settings.snapshot.hangReports }) {
                guard let self else { return }
                await follow(settingOn: on, settings: settings, asks: asks, firstWindow: firstWindow)
            }
        }
    }

    /// The policy's decision for the setting's value now, then sends, or asks once this launch.
    private func follow(settingOn: Bool, settings: SettingsController, asks: SidebarAsks,
                        firstWindow: @escaping @MainActor () async -> Void) async {
        let decision = Self.decision(defaults: defaults, settingOn: settingOn)
        await apply(decision == .send, settingOn: settingOn)
        guard decision == .confirm || decision == .invite, !askedThisLaunch.contains(decision) else { return }
        askedThisLaunch.insert(decision)
        // task-owner: one question after the first frame; it ends when the person answers.
        Task { [weak self] in
            await firstWindow()
            await self?.ask(asks: asks, settings: settings)
        }
    }

    /// Quitting: the watchdog's findings wait on disk for the next launch's report.
    func applicationWillTerminate() {
        service?.saveForNextLaunch()
    }

    /// View Hang Report: the last report sent, else a preview; opened in a cmux file tab.
    func viewReport(open: @escaping @MainActor (URL) -> Void) {
        guard let service else { return }
        // task-owner: one read and open; nothing to cancel.
        Task { [memory] in
            await memory?.sampleNow(.report)
            guard let url = await service.viewableReport() else { return }
            open(url)
        }
    }

    /// Reports on (`send`) or off. Off with the setting off also removes this Mac's consent, so a
    /// file that turns reports on again needs a new click.
    private func apply(_ on: Bool, settingOn: Bool) async {
        guard let service else { return }
        if !settingOn { defaults.removeObject(forKey: Self.consentKey) }
        await service.setEnabled(on)
        // The catalog's Release intervals reach MetricKit only while reports are on.
        SignpostMetricKitMirror.shared.setOn(on)
        if on {
            if subscriber == nil {
                // MetricKit hands over payloads it kept from before the consent: dropped.
                let since = defaults.object(forKey: Self.consentKey) as? Date ?? Date()
                let subscriber = MetricKitSubscriber(since: since) { [memory] input in
                    // task-owner: one delivery handed to the service actor, after the memory sample it carries.
                    Task {
                        await memory?.sampleNow(.report)
                        await service.receive(input)
                    }
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

    /// The person's own write of `path` (`SettingsController.userWillWrite`, before the file
    /// write): `true` for the hang reports setting records this Mac's consent, so a Not Now on the
    /// invitation followed by the Settings switch in the same launch sends; any other value
    /// removes it. Returns the undo `setSetting` runs when the write then fails, so a failed `true`
    /// leaves no record that a later synced or edited file could use.
    static func recordUserWrite(defaults: UserDefaults, path: [String], value: CmuxNextSettings.JSONValue?) -> (@MainActor () -> Void)? {
        guard path == HangReportsSetting.path else { return nil }
        guard value == .bool(true) else {
            // Off stays off even if the write fails: with no record nothing sends.
            defaults.removeObject(forKey: consentKey)
            return nil
        }
        let previous = defaults.object(forKey: consentKey) as? Date
        defaults.set(Date(), forKey: consentKey)
        return { [defaults] in
            if let previous { defaults.set(previous, forKey: consentKey) } else { defaults.removeObject(forKey: consentKey) }
        }
    }

    /// The policy over this app's defaults (``HangReportAskPolicy``).
    static func decision(defaults: UserDefaults, settingOn: Bool) -> HangReportAskPolicy.Decision {
        HangReportAskPolicy().decision(settingOn: settingOn, consented: defaults.object(forKey: consentKey) is Date,
                                       invited: defaults.bool(forKey: askedKey),
                                       telemetryOptIn: CrashReportingPolicy.telemetryOptIn(in: defaults))
    }

    /// The question on the sidebar's notice card (no dialog), as an invitation or as the confirm
    /// of a setting this Mac never agreed to. Any answer, the x included, marks the invitation
    /// asked; only Send Hang Reports records consent: through the person's write of the setting
    /// (``recordUserWrite(defaults:path:value:)``, undone if the write fails), or directly when
    /// the file already has it on.
    private func ask(asks: SidebarAsks, settings: SettingsController) async {
        let decision = Self.decision(defaults: defaults, settingOn: settings.snapshot.hangReports)
        guard decision == .confirm || decision == .invite else { return }
        let yes = await asks.ask(HangReportsStrings.askTitle, detail: HangReportsStrings.privacySummary, symbol: "gauge.with.dots.needle.33percent",
                                 yes: HangReportsStrings.askYes, no: HangReportsStrings.askNo)
        defaults.set(true, forKey: Self.askedKey)
        guard yes else { return }
        if settings.snapshot.hangReports {
            // Already on in the file: the setting will not change, so record and follow it now.
            defaults.set(Date(), forKey: Self.consentKey)
            await apply(true, settingOn: true)
            return
        }
        guard let descriptor = SettingsSchema.descriptor(for: HangReportsSetting.path) else { return }
        do { try await settings.setSetting(descriptor, to: .bool(true), by: .user) } catch {
            logger.error("diagnostics.hangReports not written: \(String(describing: error), privacy: .public)")
        }
    }
}

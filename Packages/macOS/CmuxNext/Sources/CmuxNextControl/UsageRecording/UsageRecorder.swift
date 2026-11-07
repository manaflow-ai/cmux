import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation
import os

/// Opt-in usage recording (Leo 2026-11-07: "how much in agent chats/in browsers/with what
/// splits/what most frequently clicked on or commands used"): follows
/// `diagnostics.usageRecording`, switches the daemon's recording on and off, and hands it the
/// shape of what happens, never content: where the keyboard is, each action run with its
/// entrypoint and time, the app's activity, and counts of what is open. The daemon writes it to
/// local files (cmux-tui/crates/cmux-usage), which the Rust report reads; nothing leaves the Mac.
///
/// It records only with the setting on and this Mac's consent record, which only the person's own
/// write sets (cmux-next.json syncs between Macs and agents can edit it), as hang reports do: a file
/// that turns it on without a record asks once per launch (``UsageRecordingHost/usageAsk(_:detail:yes:no:)``),
/// never an invitation.
/// A managed `DisableTelemetry` turns it off. Every channel may record.
///
/// Nothing runs on an interaction while off. While on, a focus change is a compare and a short lock
/// (``UsageEventQueue/stage(_:)``), the action runs come off the main actor in the budget
/// reporter's batches (``ActionBudgetReporter/setRunSink(_:)``), and the counts are taken only at
/// the switch-on, on resigning active and at quit. No timers, no observers of its own: the app
/// hands it each settled focus (``noteFocus(appActive:windowKey:kind:tab:)``), which also carries
/// the app's activity.
///
/// ```swift
/// let recorder = UsageRecorder(host: services)
/// recorder.start(settings: settings, firstWindow: { await firstFrame.opened() })
/// recorder.attach(actions: control.actionBudget)
/// ```
@MainActor
public final class UsageRecorder {
    /// This Mac's consent record: the time of the person's own yes (the card's Record Usage, or a
    /// `SettingWriter.user` write of the setting). Turning recording off removes it.
    public static let consentKey = "cmux.next.usageRecording.consentedAt"

    /// What the recorder reaches outside itself (``init(host:)`` makes them from the app's host).
    struct Ports {
        /// `nightly`, `dev`, `rc` or `release` (the record's file is `app-<channel>`).
        var channel: String
        /// The build number.
        var build: String
        /// How the previous run ended: `clean`, `crash`, `hang` or `unknown`.
        var previousRun: @MainActor () -> String
        /// What is open now (an O(workspaces) walk).
        var counts: @MainActor () -> UsageCounts
        /// The app is active.
        var appActive: @MainActor () -> Bool
        /// The confirm card (title, detail, yes, no): true for yes.
        var ask: @MainActor (String, String, String, String) async -> Bool
        /// `usage-set-enabled`.
        var setEnabled: @Sendable (Bool) async throws -> Void
        /// `usage-record`: the source stem and the events text.
        var record: @Sendable (String, String) async throws -> Void
    }

    /// What to do with the setting's value and this Mac's record.
    public enum Decision: Sendable, Hashable {
        /// Record.
        case record
        /// The setting is on but this Mac never agreed: ask, record nothing yet.
        case confirm
        /// Record nothing, ask nothing.
        case off
    }

    /// The keyboard's place as last recorded.
    private struct Focus: Equatable {
        var surface: UsageSurface
        var tab: String?
    }

    private let ports: Ports
    private let defaults: UserDefaults
    /// Whether a managed profile forces `DisableTelemetry` (read off the main thread at start).
    private let managedDisables: @Sendable () -> Bool
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "usage-recording")
    private var settingsObservation: Task<Void, Never>?
    /// The action budget reporter, once the control socket made it (``attach(actions:)``).
    private var actions: ActionBudgetReporter?
    /// The events of this on-period; nil while off.
    private var queue: UsageEventQueue?
    private var lastFocus: Focus?
    private var lastActive: Bool?
    /// The daemon's switch as last confirmed; nil before the first decision (then it is sent either
    /// way, so a marker an earlier run left on goes off when this one does not record).
    private var switchSent: Bool?
    /// The latest decision; the daemon's switch follows it.
    private var switchWanted = false
    /// The one switch on its way to the daemon, not yet answered. Switches go one at a time, so an
    /// answer never lands after a newer switch and leaves the marker on after the person's off.
    private var switchInFlight: Bool?
    private var launchRecorded = false
    private var askedThisLaunch = false
    /// Team sharing, the second opt-in (nil: none in this build or test).
    let sharing: UsageSharing?

    /// - Parameters:
    ///   - ports: The app's sources and the daemon's calls.
    ///   - managedDisables: Whether a managed profile forces `DisableTelemetry` (called off main).
    ///   - defaults: Where this Mac's consent records live.
    ///   - sharing: Team sharing's ports, or nil for none.
    init(ports: Ports, managedDisables: @escaping @Sendable () -> Bool, defaults: UserDefaults = .standard,
         sharing: UsageSharing.Ports? = nil) {
        self.ports = ports
        self.managedDisables = managedDisables
        self.defaults = defaults
        self.sharing = sharing.map { UsageSharing(ports: $0, defaults: defaults) }
    }

    /// The recorder over the app (`AppServices`), its local daemon and this Mac's defaults.
    ///
    /// - Parameter host: The app's forwards (``UsageRecordingHost``).
    public convenience init(host: any UsageRecordingHost) {
        let connected: @Sendable () async throws -> DaemonConnection = { [weak host] in
            guard let connection = await host?.usageConnection() else { throw DaemonError.notConnected }
            return connection
        }
        let ports = Ports(
            channel: host.usageChannel, build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            previousRun: { [weak host] in host?.usagePreviousRun ?? "unknown" },
            counts: { [weak host] in
                guard let host else { return UsageCounts() }
                return UsageCounts(workspaces: host.usageWorkspaces, windows: host.usageWindowCount,
                                   sidebarWidth: Int(exactly: host.usageSidebarWidth.rounded()) ?? 0,
                                   isChat: host.usageIsChat)
            },
            appActive: { [weak host] in host?.usageAppActive ?? false },
            ask: { [weak host] title, detail, yes, no in await host?.usageAsk(title, detail: detail, yes: yes, no: no) ?? false },
            setEnabled: { on in try await connected().setUsageRecording(on) },
            record: { source, events in try await connected().recordUsage(source: source, events: events) })
        let sharing = UsageSharing.Ports(
            ask: { [weak host] title, detail, yes, no in await host?.usageAsk(title, detail: detail, yes: yes, no: no) ?? false },
            setSharing: { on in try await connected().setUsageSharing(on) },
            upload: { [weak host] in
                guard let host, let access = await host.usageShareAccess(), let cli = await host.usageCLI.resolve() else { return false }
                return await UsageSharing.runUpload(cli: cli, access: access)
            })
        self.init(ports: ports, managedDisables: { [weak host] in host?.usageManagedDisables() ?? false }, sharing: sharing)
    }

    /// Whether it records now.
    public var isRecording: Bool { queue != nil }

    /// The events waiting for the next batch (tests).
    var waitingEvents: Int { queue?.count ?? 0 }

    /// Follows the setting from the first load on: records only with this Mac's consent record,
    /// otherwise asks once after `firstWindow` resolves (never on `isFirstLaunch`: its first-run
    /// steps come first). A managed `DisableTelemetry` keeps it off.
    ///
    /// - Parameters:
    ///   - settings: The app's settings.
    ///   - isFirstLaunch: The first launch on this Mac.
    ///   - firstWindow: Resolves once the first window showed.
    public func start(settings: SettingsController, isFirstLaunch: Bool = false, firstWindow: @escaping @MainActor () async -> Void) {
        if isFirstLaunch { askedThisLaunch = true }
        // Chained beside hang reports' own record of the same writes (either may start first).
        settings.chainUserWillWrite { [defaults] descriptor, value in
            Self.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        sharing?.start(settings: settings, isFirstLaunch: isFirstLaunch, firstWindow: firstWindow)
        let managedDisables = managedDisables
        // task-owner: follows the setting for the life of the process (the recorder lives with it,
        // AppProcessRoot); ends at once under a managed block.
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            guard await Task.detached(priority: .utility, operation: { !managedDisables() }).value else {
                self?.apply(false)
                return
            }
            for await on in ObservationStream({ settings.snapshot.usageRecording }) {
                guard let self else { return }
                follow(settingOn: on, settings: settings, firstWindow: firstWindow)
            }
        }
    }

    /// The control socket's action budget reporter, made after the first frames: the action runs
    /// reach the record from then on.
    ///
    /// - Parameter actions: The reporter, or nil.
    public func attach(actions: ActionBudgetReporter?) {
        self.actions = actions
        if let queue { tapActions(into: queue) }
    }

    /// The decision for the setting's value now, then records, or asks once this launch.
    private func follow(settingOn: Bool, settings: SettingsController, firstWindow: @escaping @MainActor () async -> Void) {
        // Off removes this Mac's consent, so a file that turns it on again needs a new yes.
        if !settingOn { defaults.removeObject(forKey: Self.consentKey) }
        let decision = Self.decision(settingOn: settingOn, consented: Self.consented(defaults), managedOff: false)
        apply(decision == .record)
        guard decision == .confirm, !askedThisLaunch else { return }
        askedThisLaunch = true
        // task-owner: one question after the first frame; it ends when the person answers.
        Task { [weak self] in
            await firstWindow()
            await self?.ask(settings: settings)
        }
    }

    /// The confirm card. Only Record Usage records consent.
    private func ask(settings: SettingsController) async {
        guard settings.snapshot.usageRecording, !Self.consented(defaults) else { return }
        let yes = await ports.ask(Strings.askTitle, Self.privacySummary, Strings.askYes, Strings.askNo)
        // The file may have turned it off while the card was up.
        guard yes, settings.snapshot.usageRecording else { return }
        defaults.set(Date(), forKey: Self.consentKey)
        apply(true)
    }

    /// Recording on or off (``decision(settingOn:consented:managedOff:)``): the action tap and the
    /// queue, then the daemon's switch.
    func apply(_ on: Bool) {
        if on, queue == nil { begin() }
        if !on, queue != nil { end() }
        switchWanted = on
        sendSwitch()
    }

    /// Sends the latest decision when it differs from the daemon's confirmed switch and no switch is
    /// on its way; ``switched(_:queue:ok:)`` sends again when the decision changed meanwhile.
    private func sendSwitch() {
        let on = switchWanted
        guard switchInFlight == nil, switchSent != on else { return }
        switchInFlight = on
        let setEnabled = ports.setEnabled
        let queue = queue
        let logger = logger
        // task-owner: one switch of the daemon's marker (after its first connection), then (on) the
        // first batch, which the daemon records only once the marker is on; ends when the daemon answers.
        Task { [weak self] in
            do {
                try await setEnabled(on)
                await queue?.flush()
                self?.switched(on, queue: queue, ok: true)
            } catch {
                logger.error("usage-set-enabled \(on) failed: \(String(describing: error), privacy: .public)")
                self?.switched(on, queue: queue, ok: false)
            }
        }
    }

    /// The daemon answered the switch to `on`. Only an answered switch counts as sent, so the next
    /// decision sends a failed one again. A failed switch-on (an older daemon, or none) ends this
    /// on-period: nothing would be written, so nothing is kept or tapped. A decision that changed
    /// while the switch was on its way is sent now.
    private func switched(_ on: Bool, queue: UsageEventQueue?, ok: Bool) {
        switchInFlight = nil
        if ok {
            switchSent = on
            // Sharing waits for the daemon's recording marker (it refuses a share switch without it).
            if on, queue != nil { sharing?.recording(true) }
        } else if on, let queue, queue === self.queue {
            end()
        }
        if switchWanted != on { sendSwitch() }
    }

    private func begin() {
        let source = "app-" + ports.channel
        let record = ports.record
        let queue = UsageEventQueue { events in try await record(source, events) }
        self.queue = queue
        var first: [UsageEvent] = []
        if !launchRecorded {
            launchRecorded = true
            first.append(.launch(channel: ports.channel, build: ports.build, prev: ports.previousRun()))
        }
        first.append(.counts(ports.counts()))
        stage(first)
        activeChanged(ports.appActive(), flushing: false)
        tapActions(into: queue)
    }

    private func end() {
        sharing?.recording(false)
        actions?.setRunSink(nil)
        queue?.stop()
        queue = nil
        lastFocus = nil
        lastActive = nil
    }

    /// Every action run from now on, mapped off the main actor on the reporter's task.
    private func tapActions(into queue: UsageEventQueue) {
        guard let actions else { return }
        let naming = actions.naming
        actions.setRunSink { samples in
            queue.stage(UsageRecord.actions(samples, naming: naming, nowUptimeNanos: ActionBudgetMonitor.now(),
                                            nowMilliseconds: UsageRecord.nowMilliseconds()))
        }
    }

    /// A window's focus settled. Its app activity is recorded on a change (resigning also records
    /// the counts, folds the action runs since the reporter's last batch and sends what waits);
    /// the key window's place (`kind`: `FocusState.Resolved.kind`, nil while a top page covers the
    /// workspace; `tab`: its content tab) when it differs from the last one recorded. Returns at
    /// once while off.
    ///
    /// - Parameters:
    ///   - appActive: The app is active.
    ///   - windowKey: The window is the key window.
    ///   - kind: The shown focus's stable name, or nil under a top page.
    ///   - tab: The content tab the keyboard is in, if any.
    public func noteFocus(appActive: Bool, windowKey: Bool, kind: String?, tab: String?) {
        guard queue != nil else { return }
        activeChanged(appActive)
        guard appActive, windowKey else { return }
        let focus = Focus(surface: UsageSurface(kind: kind), tab: tab)
        guard focus != lastFocus else { return }
        lastFocus = focus
        stage([.focus(surface: focus.surface, tab: focus.tab)])
    }

    private func activeChanged(_ on: Bool, flushing: Bool = true) {
        guard let queue, lastActive != on else { return }
        lastActive = on
        stage([.active(on: on)])
        guard !on, flushing else { return }
        sharing?.appResigned()
        stage([.counts(ports.counts())])
        let actions = actions
        // task-owner: one fold and send; ends when the daemon answers.
        Task {
            _ = await actions?.counts()
            await queue.flush()
        }
    }

    /// Quitting: the counts, and what waits is sent (the process may end before the daemon answers).
    public func applicationWillTerminate() {
        guard let queue else { return }
        stage([.counts(ports.counts())])
        // task-owner: one last send; the process ends with it or before.
        Task { await queue.flush() }
    }

    private func stage(_ events: [UsageEvent]) {
        let at = UsageRecord.nowMilliseconds()
        queue?.stage(events.map { UsageRecord(at: at, event: $0) })
    }

    // MARK: Rules

    /// What to do: record with the setting on and this Mac's consent, ask with the setting on and
    /// no consent, else nothing (never an invitation). A managed `DisableTelemetry` is always off.
    ///
    /// - Parameters:
    ///   - settingOn: `diagnostics.usageRecording` is on in the file.
    ///   - consented: This Mac holds the person's consent record.
    ///   - managedOff: A managed profile forces `DisableTelemetry`.
    /// - Returns: The decision.
    public static func decision(settingOn: Bool, consented: Bool, managedOff: Bool) -> Decision {
        guard settingOn, !managedOff else { return .off }
        return consented ? .record : .confirm
    }

    /// This Mac holds the person's consent record.
    public static func consented(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: consentKey) is Date }

    /// The person's own write of `path` (`SettingsController.userWillWrite`, before the file
    /// write): `true` for the usage recording setting records this Mac's consent; any other value
    /// removes it. Returns the undo `setSetting` runs when the write then fails.
    ///
    /// - Parameters:
    ///   - defaults: Where the record lives.
    ///   - path: The written key path.
    ///   - value: The written value (nil: removed).
    /// - Returns: The undo of the record, or nil.
    public static func recordUserWrite(defaults: UserDefaults, path: [String], value: CmuxNextSettings.JSONValue?) -> (@MainActor () -> Void)? {
        guard path == UsageRecordingSetting.path else { return nil }
        guard value == .bool(true) else {
            defaults.removeObject(forKey: consentKey)
            return nil
        }
        let previous = defaults.object(forKey: consentKey) as? Date
        defaults.set(Date(), forKey: consentKey)
        return { [defaults] in
            if let previous { defaults.set(previous, forKey: consentKey) } else { defaults.removeObject(forKey: consentKey) }
        }
    }

    /// What the record holds and never holds: the card's detail, and the confirmation sheet of
    /// `cmux settings set diagnostics.usageRecording true --confirm` (both record consent).
    public static var privacySummary: String {
        String(localized: "usageRecording.privacySummary",
               defaultValue: "cmux keeps a local record of which surfaces you use, which commands run and how, their timings, and counts of open windows, panes and tabs. It never holds file names, paths, web addresses, titles, terminal or chat text, or anything you type, and it never leaves this Mac.",
               bundle: .module)
    }

    /// The confirm card's texts (Localizable.xcstrings).
    private enum Strings {
        static var askTitle: String {
            String(localized: "usageRecording.ask.title", defaultValue: "Record Usage on This Mac?", bundle: .module)
        }

        static var askYes: String {
            String(localized: "usageRecording.ask.yes", defaultValue: "Record Usage", bundle: .module)
        }

        static var askNo: String {
            String(localized: "usageRecording.ask.no", defaultValue: "Not Now", bundle: .module)
        }
    }
}

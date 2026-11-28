import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextMacScreen
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

nonisolated private let setupLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Computer Use Setup reads the signed host's state and its Accessibility and Screen Recording
/// grants for Settings, onboarding and the CLI. The host is cmux Remote in builds that embed it,
/// otherwise the bundled Screen Sharing helper. A status read never starts the on-demand worker.
/// The palette and CLI action (`palette.computerUse.setup`), the Settings card and the onboarding
/// step all read it; the two grant actions open the guided window at their grant.
///
/// Nothing polls. A read runs when an input changes (the setting, policy, cmux Remote starting
/// or stopping), when the app becomes active (the person comes back from System Settings), and
/// when macOS posts its Accessibility trust change. A host that started but does not answer yet
/// gets a few reads spaced by `Backoff` (a retry after a failure, never a period).
@MainActor
@Observable
final class ComputerUseSetup {
    enum Phase: String, Equatable, Sendable {
        /// `DisabledFeatures` (MDM) turned Computer Use off.
        case disabledByPolicy = "disabled_by_policy"
        /// `computerUse.mode` is "off": nothing runs for it, the grants are unknown.
        case off
        /// On, but no Computer Use host is available.
        case unavailable
        /// On, and the host is starting or has not answered yet.
        case starting
        /// The host did not answer within the read budget, or its worker kept exiting: Restart.
        case failed
        /// The host answered: `permissions` are its grants.
        case ready
        /// The host answered in another shape: the grants are unknown.
        case versionMismatch = "version_mismatch"
    }

    /// The Computer Use host for this app, as the inputs see it.
    enum HostState: Equatable, Sendable {
        /// Not running yet (the daemon starts it).
        case off
        /// Running; the pid tells a restarted host from the one that answered.
        case running(pid_t)
        /// The daemon supervises the Screen Sharing helper. Recheck when its connection changes.
        case screenSharing(ObjectIdentifier)
        /// There is no connected host.
        case unavailable
        /// Its Computer Use worker could not start.
        case failed
    }

    /// What the phase follows; every field is read from observable state.
    struct Inputs: Equatable {
        var disabledByPolicy: Bool
        var enabled: Bool
        var helper: HostState
    }

    /// One grants read.
    enum Read: Equatable, Sendable {
        /// The grants, and the app bundle of the process that answered (when known).
        case answered(ComputerUsePermissions, helper: URL?)
        case versionMismatch
        /// The daemon reported a phase without grants (off, unavailable, or starting).
        case hostPhase(Phase)
        /// No answer (the host is not up yet, or the read timed out).
        case noAnswer
    }

    private(set) var phase: Phase = .off { didSet { rechecking = false } }
    /// The host's grants; meaningful only while `phase` is `.ready`.
    private(set) var permissions: ComputerUsePermissions = .none
    /// The host bundle the grants belong to (the running copy, else the embedded one).
    /// Nil when this build has none.
    private(set) var helperAppURL: URL?
    /// A read of the answered host is in flight (a ``phase`` ends it): the chats read `starting` until it answers.
    private(set) var rechecking = false

    /// cmux Remote's Computer Use worker (the App's setup only): the card's engine, worker and saved approvals.
    @ObservationIgnored var remote: CmuxRemoteComputerUseState?
    @ObservationIgnored private let inputs: @MainActor () -> Inputs
    @ObservationIgnored private let read: @Sendable () async -> Read
    @ObservationIgnored private let resolveHelper: @Sendable (URL?) async -> URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let restartHelper: @MainActor () async -> Void
    @ObservationIgnored private let requestPermission: @MainActor (ComputerUsePermissionPane) -> Void
    @ObservationIgnored private let enableSetting: @MainActor () -> Void
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private let distributed: NotificationCenter
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var observers: [MainActorObservation] = []
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resolvedFor: URL??
    /// The host whose answer `permissions` holds.
    @ObservationIgnored private var answeredBy: HostState?
    /// The inputs `start()` applied, until the input stream's first value.
    @ObservationIgnored private var appliedAtStart: Inputs?
    /// The helper app was dropped into a System Settings list (`recheckAfterGrant()`): the next
    /// time cmux Remote fails or stops answering it is restarted once, since macOS's "Quit &
    /// Reopen" after a grant quits it. Cleared by that restart, both grants on, or the step's end.
    @ObservationIgnored private(set) var restartsAfterGrant = false
    /// Maximum reads per check while the host has not answered.
    static let maximumRetries = 6

    /// macOS posts this (distributed) when any process's Accessibility trust changes.
    static let accessibilityTrustChanged = Notification.Name("com.apple.accessibility.api")

    init(inputs: @escaping @MainActor () -> Inputs,
         read: @escaping @Sendable () async -> Read = ComputerUseSetup.noRead,
         resolveHelper: @escaping @Sendable (URL?) async -> URL? = ComputerUseSetup.embeddedHelper,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.openInBackground($0) },
         restartHelper: @escaping @MainActor () async -> Void = ComputerUseSetup.noHelperRestart,
         requestPermission: @escaping @MainActor (ComputerUsePermissionPane) -> Void = { _ in },
         enableSetting: @escaping @MainActor () -> Void = {},
         notifications: NotificationCenter = .default,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.inputs = inputs
        self.read = read
        self.resolveHelper = resolveHelper
        self.openURL = openURL
        self.restartHelper = restartHelper
        self.requestPermission = requestPermission
        self.enableSetting = enableSetting
        self.notifications = notifications
        self.distributed = distributed
        self.clock = clock
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
        reading?.cancel()
    }

    /// Follows the inputs and the recheck events for the app's life. Idempotent.
    /// The current inputs apply at once, so a model made on demand (the first
    /// `computer_use.status`) never reports the initial `.off` of a feature
    /// that is on; the stream's first value repeats them and is skipped.
    func start() {
        guard observation == nil else { return }
        let inputs = inputs
        let initial = inputs()
        appliedAtStart = initial
        apply(initial)
        observation = Task { [weak self] in
            for await value in ObservationStream({ inputs() }) {
                guard let self else { return }
                if let started = appliedAtStart {
                    appliedAtStart = nil
                    if started == value { continue }
                }
                apply(value)
            }
        }
        // The person comes back from System Settings: the grant may have changed.
        observers.append(MainActorObservation(NSApplication.didBecomeActiveNotification, center: notifications) { [weak self] in
            self?.recheck()
        })
        observers.append(MainActorObservation(Self.accessibilityTrustChanged, center: distributed) { [weak self] in
            self?.recheck()
        })
    }

    /// Reads the grants again with a fresh budget (Settings, onboarding or an app event).
    func recheck() {
        apply(inputs())
    }

    /// The helper app was dropped into a list (the onboarding step's drag panel): reads the grants
    /// again, and arms one restart for when cmux Remote fails or stops answering before the grants
    /// are both on. Event driven: the restart follows the read's own failure, never a timer.
    func recheckAfterGrant() {
        restartsAfterGrant = true
        recheck()
    }

    /// The onboarding step ended: a later failure is the Restart button's, not an automatic restart.
    func endGrantWatch() { restartsAfterGrant = false }

    /// cmux Remote failed or stopped answering: restarts it once after a drop, then reads again.
    private func restartAfterGrantIfArmed() {
        guard restartsAfterGrant else { return }
        restartsAfterGrant = false
        guard let restart = prepareRestart() else { return }
        setupLogger.info("cmux Remote stopped answering after a grant: restarting it once")
        // task-owner: one helper restart after a grant; a newer apply's generation makes it a no-op.
        Task { await restart() }
    }

    /// Shows progress now and returns the shared restart work for the action or step.
    func prepareRestart() -> (@MainActor () async -> Void)? {
        let current = inputs()
        guard current.enabled, !current.disabledByPolicy, current.helper != .unavailable else { return nil }
        generation &+= 1
        let restartGeneration = generation
        reading?.cancel()
        reading = nil
        settle(.starting, running: nil)
        return { [weak self] in
            guard let self, self.generation == restartGeneration else { return }
            let current = self.inputs()
            guard current.enabled, !current.disabledByPolicy, current.helper != .unavailable else { return }
            await self.restartHelper()
            self.recheck()
        }
    }

    /// Asks the host for the grant (`requestPermission`: macOS names the host in its
    /// prompt, and lists it in System Settings) and opens the Privacy & Security list for `pane`;
    /// the read on the app's next activation picks up the change.
    func open(_ pane: ComputerUsePermissionPane) {
        guard let url = Self.settingsURL(pane) else { return }
        requestPermission(pane)
        openURL(url)
    }

    /// No host to restart (tests, and setups built without one). A named function, not a
    /// closure literal: an async closure default argument is a crash class (crash_ratchet).
    static func noHelperRestart() async {}

    /// No host to read (tests that never reach `.running`).
    nonisolated static func noRead() async -> Read { .noAnswer }

    /// Turns Computer Use on and reads its host's grants after the person clicks in onboarding.
    func enable() {
        guard phase == .off else { return }
        enableSetting()
    }

    static func settingsURL(_ pane: ComputerUsePermissionPane) -> URL? {
        let anchor = switch pane {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// What the onboarding step shows: the grants, or why they are unknown.
    var stepPermissions: ComputerUsePermissions {
        switch phase {
        case .ready: permissions
        case .versionMismatch: .helperVersionMismatch
        case .off: .off
        case .failed: .helperFailed
        case .starting: .reading
        case .disabledByPolicy, .unavailable: .none
        }
    }

    // MARK: Phase

    private func apply(_ inputs: Inputs) {
        generation &+= 1
        reading?.cancel()
        reading = nil
        if inputs.disabledByPolicy { return settle(.disabledByPolicy, running: nil) }
        guard inputs.enabled else { return settle(.off, running: nil) }
        switch inputs.helper {
        case .unavailable: settle(.unavailable, running: nil)
        case .failed:
            settle(.failed, running: nil)
            restartAfterGrantIfArmed()
        // On, and the daemon is starting cmux Remote.
        case .off: settle(.starting, running: nil)
        case .running, .screenSharing:
            // Until this host answers, the grants are being read, not off; one that answered keeps its card grants.
            if phase != .ready || answeredBy != inputs.helper { settle(.starting, running: nil) } else { rechecking = true }
            readGrants(host: inputs.helper, generation: generation)
        }
    }

    /// A phase without a read: the grants are unknown, and the host the grants would belong to
    /// is the embedded one.
    private func settle(_ phase: Phase, running: URL?) {
        self.phase = phase
        if phase != .ready { permissions = .none }
        resolve(running: running)
    }

    private func readGrants(host: HostState, generation current: Int) {
        let read = read
        let clock = clock
        // task-owner: one read (plus bounded retries while a started host is not up yet); a newer apply cancels it.
        reading = Task { [weak self] in
            var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(4))
            for attempt in 0..<Self.maximumRetries {
                let result = await read()
                guard let self, !Task.isCancelled, self.generation == current else { return }
                switch result {
                case .answered(let granted, let helper):
                    phase = .ready
                    permissions = granted
                    answeredBy = host
                    if granted.accessibility, granted.screenRecording { restartsAfterGrant = false }
                    resolve(running: helper)
                    return
                case .versionMismatch:
                    setupLogger.error("The Computer Use host answered its status in another shape")
                    settle(.versionMismatch, running: nil)
                    return
                case .hostPhase(let phase) where phase != .starting:
                    settle(phase, running: nil)
                    if phase == .failed { restartAfterGrantIfArmed() }
                    return
                case .noAnswer, .hostPhase:
                    let hasRetry = attempt + 1 < Self.maximumRetries
                    settle(hasRetry ? .starting : .failed, running: nil) // ends an earlier answer: a host that keeps its pid but stops answering is not ready
                    // The read budget ran out after a drop: the helper macOS quit for the grant
                    // (or a copy it reopened that does not answer) is restarted once.
                    guard hasRetry else { return restartAfterGrantIfArmed() }
                    // concurrency-allow: Backoff.wait is an async sleep after a failed read, not a poll period.
                    do { try await backoff.wait(owner: "computer-use.setup.read", clock: clock) } catch { return }
                }
            }
        }
    }

    /// Resolves the host bundle for `running` (or the embedded one), once per running copy.
    private func resolve(running: URL?) {
        guard resolvedFor != .some(running) else { return }
        resolvedFor = .some(running)
        let resolveHelper = resolveHelper
        // task-owner: one bundle lookup per host identity; a newer one wins (resolvedFor).
        Task { [weak self] in
            let url = await awaitConcurrently({ await resolveHelper(running) })
            guard let self, resolvedFor == .some(running) else { return }
            helperAppURL = url
        }
    }

    // MARK: The App's reads

    /// The two grants out of cmux Remote's host status (`permissions`), with the app bundle of
    /// the host that answered; nil when the status has no probe answer yet.
    nonisolated static func grants(fromStatus status: [String: Any]) -> Read? {
        guard let fields = status["permissions"] as? [String: Any] else { return nil }
        guard let accessibility = fields["accessibility"] as? Bool, let screen = fields["screen_recording"] as? Bool else {
            return .versionMismatch
        }
        var helper: URL?
        if let pid = status["pid"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL,
           app.pathExtension == "app" {
            helper = app
        }
        return .answered(ComputerUsePermissions(accessibility: accessibility, screenRecording: screen), helper: helper)
    }

    /// The running host, else this build's signed Computer Use host.
    @concurrent nonisolated static func embeddedHelper(_ running: URL?) async -> URL? {
        running ?? ComputerUseRemoteBundle.embedded()?.appURL ?? MacScreenHelper.bundled()?.app
    }

    @concurrent nonisolated private static func screenSharingRead(_ status: CmuxNextDaemon.JSONValue?) async -> Read {
        guard let helper = MacScreenHelper.bundled() else { return .hostPhase(.unavailable) }
        guard let host = status?["computer_use"] else { return .noAnswer }
        if host["mode"]?.stringValue == "off" { return .hostPhase(.off) }
        switch host["state"]?.stringValue {
        case "idle", "ready":
            guard let grants = await helper.permissions() else { return .noAnswer }
            let permissions = ComputerUsePermissions(accessibility: grants.accessibility, screenRecording: grants.screenRecording)
            return .answered(permissions, helper: helper.app)
        case "starting": return .hostPhase(.starting)
        case "off": return .hostPhase(.off)
        case "unavailable": return .hostPhase(.unavailable)
        default: return .versionMismatch
        }
    }
}

extension ComputerUseSetup {
    /// The App's setup: `computerUse.mode`, `DisabledFeatures` and cmux Remote
    /// (``CmuxRemoteService``, its host status through the daemon).
    static func app(services: AppServices) -> ComputerUseSetup {
        let remote = services.cmuxRemote
        let remoteState = remote.computerUse
        let setup = ComputerUseSetup(
            inputs: { [weak services] in
                let mode = services?.settings?.snapshot.computerUse.mode ?? .off
                let helper: HostState
                if remoteState.embedded {
                    helper = remoteState.computerUseFailed ? .failed : remoteState.hostPID.map { .running($0) } ?? .off
                } else {
                    helper = services?.daemon.connection.map { .screenSharing(ObjectIdentifier($0)) } ?? .unavailable
                }
                return Inputs(disabledByPolicy: services?.registry.disabledFeatures.contains(.computerUse) ?? true,
                              enabled: mode != .off, helper: helper)
            },
            read: { @MainActor [weak remote] in
                guard let remote else { return .noAnswer }
                if !remote.computerUse.embedded {
                    return await ComputerUseSetup.screenSharingRead(try? await remote.status())
                }
                guard let status = await remote.computerUseStatus() else { return .noAnswer }
                return ComputerUseSetup.grants(fromStatus: status) ?? .noAnswer
            },
            restartHelper: { [weak remote] in await remote?.restartComputerUse() },
            requestPermission: { [weak services, weak remote] pane in
                guard let services, let settings = services.settings,
                      !services.registry.disabledFeatures.contains(.computerUse) else { return }
                // task-owner: one setup click; turning Computer Use on finishes before its grant request.
                Task {
                    do {
                        if settings.snapshot.computerUse.mode == .off {
                            try await settings.setSetting(at: ComputerUseSettings.modePath, to: .string(ComputerUseMode.fullAccess.rawValue),
                                                          by: SettingWriter.currentRun())
                        }
                        await remote?.requestGrant(pane == .screenRecording ? "screen-recording" : "accessibility")
                    } catch {
                        setupLogger.error("Computer Use could not request permission: \(String(describing: error), privacy: .public)")
                    }
                }
            },
            enableSetting: { [weak services] in
                guard let settings = services?.settings else { return }
                let writer = SettingWriter.currentRun()
                // task-owner: one settings write; cmux Remote's start follows the setting.
                Task {
                    do {
                        try await settings.setSetting(at: ComputerUseSettings.modePath, to: .string(ComputerUseMode.fullAccess.rawValue), by: writer)
                    } catch {
                        setupLogger.error("Computer Use could not be turned on: \(String(describing: error), privacy: .public)")
                    }
                }
            })
        setup.remote = remoteState
        setup.start()
        return setup
    }
}

extension ComputerUseSetup {
    /// The Settings page's Computer Use card (`cmux.settings.host.lists`
    /// `computer_use`) and `computer_use.status`: live through
    /// `cmux.settings.host.changed`, since the host lists read this
    /// observable model. Grants are null while unknown; `helper` names the
    /// app that holds them.
    var pageJSON: CmuxNextSettings.JSONValue {
        let known = phase == .ready
        var fields: [String: CmuxNextSettings.JSONValue] = [
            "phase": .string(phase.rawValue),
            "accessibility": known ? .bool(permissions.accessibility) : .null,
            "screen_recording": known ? .bool(permissions.screenRecording) : .null,
            "helper": helperAppURL.map { .string($0.deletingPathExtension().lastPathComponent) } ?? .null,
        ]
        remote?.addSettingsFields(to: &fields)
        return .object(fields)
    }
}

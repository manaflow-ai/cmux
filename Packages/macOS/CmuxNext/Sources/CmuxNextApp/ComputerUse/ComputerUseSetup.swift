import AppKit
import CmuxNextCompat
import CmuxNextMacScreen
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

nonisolated private let setupLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Computer Use Setup: the one place that knows whether cmux Remote, the signed host whose
/// Computer Use worker runs the cmux Computer Use engine (docs/cmux-remote.md), holds
/// Accessibility and Screen Recording. The palette and CLI action (`palette.computerUse.setup`),
/// the Settings card and the onboarding step all read it, and the two grant actions open System
/// Settings through it.
///
/// macOS gives both grants to cmux Remote, not to cmux, so the grants are read from cmux
/// Remote's own probe (its host status through the cmux-tui daemon; a fresh process reads
/// AXIsProcessTrusted and CGPreflightScreenCaptureAccess, never a prompt). With Computer Use
/// off (`computerUse.mode` "off") nothing runs for it and the grants are unknown; the phase says
/// so instead of reporting "not granted".
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
        /// On, but this build embeds no cmux Remote (or its daemon does not run it).
        case unavailable
        /// On, and cmux Remote is starting (or has not answered yet).
        case starting
        /// cmux Remote did not answer within the read budget, or its worker kept exiting: Restart.
        case failed
        /// cmux Remote answered: `permissions` are its grants.
        case ready
        /// cmux Remote answered in another shape: the grants are unknown.
        case versionMismatch = "version_mismatch"
    }

    /// cmux Remote for this app, as the inputs see it.
    enum HostState: Equatable, Sendable {
        /// Not running yet (the daemon starts it).
        case off
        /// Running; the pid tells a restarted host from the one that answered.
        case running(pid_t)
        /// This build has no cmux Remote, or the daemon does not run it.
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
        /// No answer (the host is not up yet, or the read timed out).
        case noAnswer
    }

    private(set) var phase: Phase = .off
    /// cmux Remote's grants; meaningful only while `phase` is `.ready`.
    private(set) var permissions: ComputerUsePermissions = .none
    /// The cmux Remote bundle the grants belong to (the running copy, else the embedded one).
    /// Nil when this build has none.
    private(set) var helperAppURL: URL?

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
    /// The host whose answer `permissions` holds (a restarted host has another pid).
    @ObservationIgnored private var answeredBy: pid_t?
    /// The inputs `start()` applied, until the input stream's first value.
    @ObservationIgnored private var appliedAtStart: Inputs?
    /// Maximum reads per check while the host has not answered.
    static let maximumRetries = 6

    /// macOS posts this (distributed) when any process's Accessibility trust changes.
    static let accessibilityTrustChanged = Notification.Name("com.apple.accessibility.api")

    init(inputs: @escaping @MainActor () -> Inputs,
         read: @escaping @Sendable () async -> Read = ComputerUseSetup.noRead,
         resolveHelper: @escaping @Sendable (URL?) async -> URL? = ComputerUseSetup.embeddedRemote,
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

    /// Asks cmux Remote for the grant (`requestPermission`: macOS names cmux Remote in its
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

    /// Turns Computer Use on (the person's own click in onboarding). cmux Remote then starts and
    /// its grants are read.
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
        case .disabledByPolicy, .unavailable, .starting: .none
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
        case .failed: settle(.failed, running: nil)
        // On, and the daemon is starting cmux Remote.
        case .off: settle(.starting, running: nil)
        case .running(let pid):
            // Until this host answers, the grants are being read, not off.
            if phase != .ready || answeredBy != pid { settle(.starting, running: nil) }
            readGrants(pid: pid, generation: generation)
        }
    }

    /// A phase without a read: the grants are unknown, and the host the grants would belong to
    /// is the embedded one.
    private func settle(_ phase: Phase, running: URL?) {
        self.phase = phase
        if phase != .ready { permissions = .none }
        resolve(running: running)
    }

    private func readGrants(pid: pid_t, generation current: Int) {
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
                    answeredBy = pid
                    resolve(running: helper)
                    return
                case .versionMismatch:
                    setupLogger.error("cmux Remote answered its status in another shape")
                    settle(.versionMismatch, running: nil)
                    return
                case .noAnswer:
                    // A host that answered before keeps its rows until a read succeeds.
                    let hasRetry = attempt + 1 < Self.maximumRetries
                    if phase != .ready { settle(hasRetry ? .starting : .failed, running: nil) }
                    guard hasRetry else { return }
                    // concurrency-allow: Backoff.wait is an async sleep after a failed read, not a poll period.
                    do { try await backoff.wait(owner: "computer-use.setup.read", clock: clock) } catch { return }
                }
            }
        }
    }

    /// Resolves the cmux Remote bundle for `running` (or the embedded one), once per running copy.
    private func resolve(running: URL?) {
        guard resolvedFor != .some(running) else { return }
        resolvedFor = .some(running)
        let resolveHelper = resolveHelper
        // task-owner: one bundle lookup per host identity; a newer one wins (resolvedFor).
        Task { [weak self] in
            let url = await resolveHelper(running)
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

    /// The running cmux Remote, else the copy this app embeds (`Contents/Library`).
    @concurrent nonisolated static func embeddedRemote(_ running: URL?) async -> URL? {
        if let running { return running }
        return ComputerUseRemoteBundle.embedded()?.appURL
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
                let helper: HostState = !remoteState.embedded ? .unavailable
                    : remoteState.computerUseFailed ? .failed
                    : remoteState.hostPID.map { .running($0) } ?? .off
                return Inputs(disabledByPolicy: services?.registry.disabledFeatures.contains(.computerUse) ?? true,
                              enabled: mode != .off, helper: helper)
            },
            read: { @MainActor [weak remote] in
                guard let status = await remote?.computerUseStatus() else { return .noAnswer }
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
    /// app that holds them (cmux Remote).
    var pageJSON: CmuxNextSettings.JSONValue {
        let known = phase == .ready
        var fields: [String: CmuxNextSettings.JSONValue] = [
            "phase": .string(phase.rawValue),
            "accessibility": known ? .bool(permissions.accessibility) : .null,
            "screen_recording": known ? .bool(permissions.screenRecording) : .null,
            "helper": helperAppURL.map { .string($0.deletingPathExtension().lastPathComponent) } ?? .null,
        ]
        guard let remote, remote.embedded else { return .object(fields) }
        fields["engine"] = .string(Self.engineName)
        let state: String = switch remote.workerState {
        case "ready": "running"
        case "starting": "starting"
        case "unavailable": "failed"
        default: "stopped"
        }
        let pid: CmuxNextSettings.JSONValue = remote.workerPID.map { CmuxNextSettings.JSONValue.number(Double($0)) } ?? .null
        fields["worker"] = .object(["state": .string(state), "pid": pid])
        fields["approvals"] = .array(remote.approvals.map { approval -> CmuxNextSettings.JSONValue in
            .object(["app_id": .string(approval.appID), "name": .string(Self.appName(approval.appID)),
                     "decision": .string(approval.decision)])
        })
        return .object(fields)
    }

    /// The engine's name on the card (a product name, not translated).
    nonisolated static let engineName = "cmux Computer Use"

    /// An app id's display name from Launch Services, else the id.
    static func appName(_ appID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { return appID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

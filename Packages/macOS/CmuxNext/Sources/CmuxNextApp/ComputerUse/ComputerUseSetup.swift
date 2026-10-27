import AppKit
import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

nonisolated private let setupLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Computer Use Setup: the one place that knows whether the helper this app
/// uses holds Accessibility and Screen Recording. The palette and CLI action
/// (`palette.computerUse.setup`), the Settings card and the onboarding step
/// all read it, and the two grant actions open System Settings through it.
///
/// macOS gives both grants to the cmux Computer Use helper, not to cmux, so
/// the grants are read from the running helper (`permissions_status`:
/// AXIsProcessTrusted and CGPreflightScreenCaptureAccess in the helper,
/// read-only, never a prompt). With Computer Use off no helper runs and the
/// grants are unknown; the phase says so instead of reporting "not granted".
///
/// Nothing polls. A read runs when an input changes (the setting, policy, the
/// helper starting or stopping), when the app becomes active (the person comes
/// back from System Settings), and when macOS posts its Accessibility trust
/// change. A helper that started but does not answer yet gets a few reads
/// spaced by `Backoff` (a retry after a failure, never a period).
@MainActor
@Observable
final class ComputerUseSetup {
    enum Phase: String, Equatable, Sendable {
        /// `DisabledFeatures` (MDM) turned Computer Use off.
        case disabledByPolicy = "disabled_by_policy"
        /// `computerUse.enabled` is off: no helper runs, the grants are unknown.
        case off
        /// On, but this build has no Developer ID signed helper.
        case unavailable
        /// On, and the helper is starting (or has not answered yet).
        case starting
        /// The helper could not start (copy, lock, launch or check), did not
        /// answer within the read budget, or kept exiting: Restart Helper.
        case failed
        /// The helper answered: `permissions` are its grants.
        case ready
        /// The helper answered in another protocol version: the grants are unknown.
        case versionMismatch = "version_mismatch"
    }

    /// What the phase follows; every field is read from observable state.
    struct Inputs: Equatable {
        var disabledByPolicy: Bool
        var enabled: Bool
        var helper: ComputerUseHelperDaemon.State
        /// The driver chosen: this model reads the legacy helper only.
        var driver: ComputerUseDriver = .legacy
    }

    /// One `permissions_status` read.
    enum Read: Equatable, Sendable {
        /// The grants, and the app bundle of the process that answered (when known).
        case answered(ComputerUsePermissions, helper: URL?)
        case versionMismatch
        /// No answer (the socket is not up yet, or the read timed out).
        case noAnswer
    }

    private(set) var phase: Phase = .off
    /// The helper's grants; meaningful only while `phase` is `.ready`.
    private(set) var permissions: ComputerUsePermissions = .none
    /// The signed helper the grants belong to (the running one, else the one
    /// that would start). Nil when this build has none.
    private(set) var helperAppURL: URL?
    /// The driver chosen (`computerUse.driver`): the phase and grants are
    /// the legacy helper's, so a reader under the helper v2 knows they say nothing.
    private(set) var driver: ComputerUseDriver = .legacy

    @ObservationIgnored private let inputs: @MainActor () -> Inputs
    @ObservationIgnored private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    @ObservationIgnored private let read: @Sendable (AgentActivitySocketSource.Configuration) async -> Read
    @ObservationIgnored private let resolveHelper: @Sendable (URL?) async -> URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let requestGrant: @Sendable (AgentActivitySocketSource.Configuration, ComputerUsePermissionPane) async -> Void
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
    /// The helper whose answer `permissions` holds (a restarted helper has another pid).
    @ObservationIgnored private var answeredBy: pid_t?
    /// The inputs `start()` applied, until the input stream's first value.
    @ObservationIgnored private var appliedAtStart: Inputs?
    /// Maximum reads per check while the helper has not answered.
    static let maximumRetries = 6

    /// macOS posts this (distributed) when any process's Accessibility trust changes.
    static let accessibilityTrustChanged = Notification.Name("com.apple.accessibility.api")

    init(inputs: @escaping @MainActor () -> Inputs,
         configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
         read: @escaping @Sendable (AgentActivitySocketSource.Configuration) async -> Read = { await ComputerUseSetup.socketRead($0) },
         resolveHelper: @escaping @Sendable (URL?) async -> URL? = ComputerUseSetup.signedHelper,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.openInBackground($0) },
         requestGrant: @escaping @Sendable (AgentActivitySocketSource.Configuration, ComputerUsePermissionPane) async -> Void
             = ComputerUseSetup.socketRequestGrant,
         restartHelper: @escaping @MainActor () async -> Void = ComputerUseSetup.noHelperRestart,
         requestPermission: @escaping @MainActor (ComputerUsePermissionPane) -> Void = { _ in },
         enableSetting: @escaping @MainActor () -> Void = {},
         notifications: NotificationCenter = .default,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.inputs = inputs
        self.configuration = configuration
        self.read = read
        self.resolveHelper = resolveHelper
        self.openURL = openURL
        self.requestGrant = requestGrant
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
        guard current.enabled, !current.disabledByPolicy, current.driver == .legacy else { return nil }
        generation &+= 1
        let restartGeneration = generation
        reading?.cancel()
        reading = nil
        settle(.starting, running: nil)
        return { [weak self] in
            guard let self, self.generation == restartGeneration else { return }
            let current = self.inputs()
            guard current.enabled, !current.disabledByPolicy, current.driver == .legacy else { return }
            await self.restartHelper()
            self.recheck()
        }
    }

    /// Opens the Privacy & Security list for `pane` in System Settings; the
    /// read on the app's next activation picks up the change.
    /// When the helper runs, it first raises macOS's own request for the
    /// grant, attributed to the helper (`request_system_permission`, host
    /// only). On macOS 26 the Screen Recording toggle alone is not enough: the
    /// helper must ask once ("bypass the system private window picker"), or
    /// its capture check stays false (seen 2026-10-27 on macOS 26.6).
    /// Accessibility needs no such request: the toggle is enough, and the
    /// request only raised macOS's "would like to control this computer"
    /// alert on top of the drag panel that already guides the person.
    /// Under the helper v2, `requestPermission` queues the grant on its control pipe instead.
    func open(_ pane: ComputerUsePermissionPane) {
        if Self.asksHelper(pane, accessibility: permissions.accessibility, phase: phase, driver: driver),
           let configuration = configuration() {
            let requestGrant = requestGrant
            // task-owner: one host request to the helper; the next read (app activation, trust change) shows the answer.
            Task { await requestGrant(configuration, pane) }
        }
        guard let url = Self.settingsURL(pane) else { return }
        requestPermission(pane)
        openURL(url)
    }

    /// Whether Allow on `pane` first asks the running helper for the grant: Screen Recording only,
    /// with the legacy helper ready, and only once Accessibility is on. With it off, the helper's
    /// capture request also raised macOS's "would like to control this computer" alert (seen
    /// 2026-10-28 on macOS 26.6).
    nonisolated static func asksHelper(_ pane: ComputerUsePermissionPane, accessibility: Bool, phase: Phase,
                                       driver: ComputerUseDriver) -> Bool {
        pane == .screenRecording && accessibility && phase == .ready && driver == .legacy
    }

    /// No helper to restart (tests, and setups built without one). A named function, not a
    /// closure literal: an async closure default argument is a crash class (crash_ratchet).
    static func noHelperRestart() async {}

    /// One `request_system_permission` to the helper with the host token (on the
    /// main actor, as `socketRead`: `CuaSocketClient` runs the socket work off it).
    /// It answers at once and raises the prompt itself; a refusal (an older
    /// helper) only means no prompt.
    static func socketRequestGrant(_ configuration: AgentActivitySocketSource.Configuration,
                                   _ pane: ComputerUsePermissionPane) async {
        let name = switch pane {
        case .accessibility: "accessibility"
        case .screenRecording: "screen_recording"
        }
        do {
            _ = try await CuaSocketClient(configuration: configuration).send("request_system_permission", name: name,
                                                                             deadline: .seconds(2))
        } catch {
            setupLogger.notice("cmux Computer Use helper did not take the \(name, privacy: .public) request: \(String(describing: error), privacy: .public)")
        }
    }

    /// Turns Computer Use on (the person's own click in onboarding). The
    /// helper then starts and its grants are read.
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
        driver = inputs.driver
        generation &+= 1
        reading?.cancel()
        reading = nil
        if inputs.disabledByPolicy { return settle(.disabledByPolicy, running: nil) }
        guard inputs.enabled else { return settle(.off, running: nil) }
        switch inputs.helper {
        case .unavailable: settle(.unavailable, running: nil)
        case .failed: settle(.failed, running: nil)
        // On, and ComputerUseHelperDaemon is starting the helper.
        case .off: settle(.starting, running: nil)
        case .running(let pid):
            guard let configuration = configuration() else { return settle(.starting, running: nil) }
            // Until this helper answers, the grants are being read, not off.
            if phase != .ready || answeredBy != pid { settle(.starting, running: nil) }
            readGrants(configuration, pid: pid, generation: generation)
        }
    }

    /// A phase without a read: the grants are unknown, and the helper the
    /// grants would belong to is the one that would start.
    private func settle(_ phase: Phase, running: URL?) {
        self.phase = phase
        if phase != .ready { permissions = .none }
        resolve(running: running)
    }

    private func readGrants(_ configuration: AgentActivitySocketSource.Configuration, pid: pid_t, generation current: Int) {
        let read = read
        let clock = clock
        // task-owner: one read (plus bounded retries while a started helper is not up yet); a newer apply cancels it.
        reading = Task { [weak self] in
            var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(4))
            for attempt in 0..<Self.maximumRetries {
                let result = await read(configuration)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                switch result {
                case .answered(let granted, let helper):
                    phase = .ready
                    permissions = granted
                    answeredBy = pid
                    resolve(running: helper)
                    return
                case .versionMismatch:
                    setupLogger.error("cmux Computer Use helper answered permissions_status in another protocol version")
                    settle(.versionMismatch, running: nil)
                    return
                case .noAnswer:
                    // A helper that answered before keeps its rows until a read succeeds.
                    let hasRetry = attempt + 1 < Self.maximumRetries
                    if phase != .ready { settle(hasRetry ? .starting : .failed, running: nil) }
                    guard hasRetry else { return }
                    // concurrency-allow: Backoff.wait is an async sleep after a failed read, not a poll period.
                    do { try await backoff.wait(owner: "computer-use.setup.read", clock: clock) } catch { return }
                }
            }
        }
    }

    /// Resolves the signed helper for `running` (or the installed one), once per running app.
    private func resolve(running: URL?) {
        guard resolvedFor != .some(running) else { return }
        resolvedFor = .some(running)
        let resolveHelper = resolveHelper
        // task-owner: one signature check per helper identity; a newer one wins (resolvedFor).
        Task { [weak self] in
            let url = await resolveHelper(running)
            guard let self, resolvedFor == .some(running) else { return }
            helperAppURL = url
        }
    }

    // MARK: The App's reads

    /// One `permissions_status` over the helper's socket (the socket work runs off the main
    /// actor inside `CuaSocketClient`).
    static func socketRead(_ configuration: AgentActivitySocketSource.Configuration) async -> Read {
        let status: [String: Any]
        do {
            status = try await CuaSocketClient(configuration: configuration).send("permissions_status", deadline: .seconds(2))
        } catch AgentActivitySourceError.refused, AgentActivitySourceError.malformed {
            return .versionMismatch
        } catch {
            return .noAnswer
        }
        guard status["accessibility"] is Bool, status["screen_recording"] is Bool else { return .versionMismatch }
        var helper: URL?
        if let pid = (status["source"] as? [String: Any])?["pid"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL, app.pathExtension == "app" {
            helper = app
        }
        return .answered(permissions(status), helper: helper)
    }

    /// The two grants out of a `permissions_status` result.
    nonisolated static func permissions(_ status: [String: Any]) -> ComputerUsePermissions {
        ComputerUsePermissions(accessibility: status["accessibility"] as? Bool ?? false,
                               screenRecording: status["screen_recording"] as? Bool ?? false)
    }

    /// The Developer ID signed helper for `running`, else the one that would
    /// start: its verified copy outside this app (the app the grants belong
    /// to, ComputerUseHelperStaging), or the installed source before the
    /// first copy is made.
    @concurrent nonisolated static func signedHelper(_ running: URL?) async -> URL? {
        let resolved = CuaHelperIdentity().resolve(running: running,
                                                   installed: CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild))
            .helperURL
        guard running == nil, resolved != nil else { return resolved }
        return await ComputerUseHelperDaemon.stagedHelper() ?? resolved
    }
}

extension ComputerUseSetup {
    /// The App's setup: `computerUse.enabled`, `DisabledFeatures` and the
    /// helper this app runs (`ComputerUseHelperDaemon.shared`).
    static func app(services: AppServices) -> ComputerUseSetup {
        let helper = ComputerUseHelperDaemon.shared
        let setup = ComputerUseSetup(
            inputs: { [weak services] in
                Inputs(disabledByPolicy: services?.registry.disabledFeatures.contains(.computerUse) ?? true,
                       enabled: services?.settings?.snapshot.computerUse.enabled ?? false,
                       helper: helper.state,
                       driver: services?.settings?.snapshot.computerUse.driver ?? .legacy)
            },
            configuration: { helper.configuration },
            restartHelper: { await helper.restartLegacy() },
            requestPermission: { [weak services] pane in
                guard let services, let settings = services.settings,
                      settings.snapshot.computerUse.driver == .upstream,
                      !services.registry.disabledFeatures.contains(.computerUse) else { return }
                // task-owner: one setup click; enabling finishes before queuing its grant.
                Task {
                    do {
                        if !settings.snapshot.computerUse.enabled {
                            try await settings.setSetting(at: ComputerUseSettings.enabledPath, to: .bool(true), by: SettingWriter.currentRun())
                        }
                        guard settings.snapshot.computerUse.enabled, settings.snapshot.computerUse.driver == .upstream,
                              !services.registry.disabledFeatures.contains(.computerUse) else { return }
                        await helper.upstream.requestPermission(screenRecording: pane == .screenRecording)
                    } catch {
                        setupLogger.error("Computer Use could not request permission: \(String(describing: error), privacy: .public)")
                    }
                }
            },
            enableSetting: { [weak services] in
                guard let settings = services?.settings else { return }
                let writer = SettingWriter.currentRun()
                // task-owner: one settings write; the helper start follows the setting.
                Task {
                    do { try await settings.setSetting(at: ComputerUseSettings.enabledPath, to: .bool(true), by: writer) } catch {
                        setupLogger.error("Computer Use could not be turned on: \(String(describing: error), privacy: .public)")
                    }
                }
            })
        setup.start()
        return setup
    }
}

extension ComputerUseSetup {
    /// The Settings page's Computer Use card (`cmux.settings.host.lists`
    /// `computer_use`) and `computer_use.status`: live through
    /// `cmux.settings.host.changed`, since the host lists read this
    /// observable model. Grants are null while unknown. `driver` tells a
    /// reader (the agent setup check in `cmux mcp serve`) whether the grants
    /// belong to the helper that runs.
    var pageJSON: CmuxNextSettings.JSONValue {
        let known = phase == .ready
        return [
            "phase": .string(phase.rawValue),
            "accessibility": known ? .bool(permissions.accessibility) : .null,
            "screen_recording": known ? .bool(permissions.screenRecording) : .null,
            "helper": helperAppURL.map { .string($0.deletingPathExtension().lastPathComponent) } ?? .null,
            "driver": .string(driver.rawValue),
        ]
    }
}

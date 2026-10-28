import AppKit
import CmuxNextAgentActivity
import CmuxNextCompatAppKit
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
        /// On, but this build has no Developer ID signed helper (or it did not start).
        case unavailable
        /// On, and the helper is starting (or has not answered yet).
        case starting
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
    /// The helper's icon (the drag tiles show it), read on the system lane once the helper is found.
    private(set) var helperAppIcon: NSImage?
    /// The app's Launch Services answers, which read the helper's icon; nil (tests) reads none.
    @ObservationIgnored private let queries: WorkspaceQueries?

    @ObservationIgnored private let inputs: @MainActor () -> Inputs
    @ObservationIgnored private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    @ObservationIgnored private let read: @Sendable (AgentActivitySocketSource.Configuration) async -> Read
    @ObservationIgnored private let resolveHelper: @Sendable (URL?) async -> URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let enableSetting: @MainActor () -> Void
    /// The app's fan-out of app notices (the app becoming active).
    @ObservationIgnored private let appEvents: AppEvents
    /// The app's one fan-out of distributed notices: Accessibility trust here and in the permission
    /// probe (``SystemPermissionProbe``) shares its one observer.
    @ObservationIgnored let distributedEvents: AppEvents
    /// The main-thread scheduler the reads reply on and the inputs flush on.
    @ObservationIgnored private let mainWork: MainWorkScheduler
    /// Starts the reads off main at a stated priority.
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var observation: ServiceObservation<Inputs>?
    @ObservationIgnored private var reading: Task<Void, any Error>?
    /// The wait before the next read of a started helper that has not answered (``Backoff``).
    @ObservationIgnored private let retry: MainDeadline
    @ObservationIgnored private var backoff = ComputerUseSetup.retryBackoff
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resolvedFor: URL??
    /// Reads after a helper start that has not answered yet.
    static let maximumRetries = 6
    /// The waits between those reads: a retry after a failure, never a period.
    static let retryBackoff = Backoff(initial: .milliseconds(250), maximum: .seconds(4))

    /// macOS posts this (distributed) when any process's Accessibility trust changes.
    static let accessibilityTrustChanged = Notification.Name("com.apple.accessibility.api")

    init(inputs: @escaping @MainActor () -> Inputs,
         configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
         read: @escaping @Sendable (AgentActivitySocketSource.Configuration) async -> Read = { await ComputerUseSetup.socketRead($0) },
         resolveHelper: @escaping @Sendable (URL?) async -> URL?,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.openInBackground($0) },
         enableSetting: @escaping @MainActor () -> Void = {},
         appEvents: AppEvents, distributedEvents: AppEvents, deadlines: MainDeadlineScheduler, work: BackgroundWork,
         queries: WorkspaceQueries? = nil) {
        self.queries = queries
        self.inputs = inputs
        self.configuration = configuration
        self.read = read
        self.resolveHelper = resolveHelper
        self.openURL = openURL
        self.enableSetting = enableSetting
        self.appEvents = appEvents
        self.distributedEvents = distributedEvents
        mainWork = deadlines.work
        self.work = work
        // `visible`: the Settings card and the onboarding step show the grants a read finds.
        retry = MainDeadline(owner: "ComputerUseSetup.retry", workClass: .visible, scheduler: deadlines)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The read task is Sendable and stops from any thread; the observation and subscriptions stop with their release.
    nonisolated deinit {
        reading?.cancel()
    }

    /// Follows the inputs and the recheck events for the app's life. Idempotent.
    /// The current inputs apply at once (the observation applies its first value
    /// before it returns), so a model made on demand (the first
    /// `computer_use.status`) never reports the initial `.off` of a feature that is on.
    func start() {
        guard observation == nil else { return }
        // A service observation: the phase is model state the palette, the CLI and the pages read, shown or
        // not. `visible`: the cards show it; a person's toggle flushes before its frame.
        observation = ServiceObservation(.visible, owner: "ComputerUseSetup.inputs", on: mainWork, read: inputs) { [weak self] value in
            self?.apply(value)
        }
        subscriptions = [
            // The person comes back from System Settings: the grant may have changed.
            appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "ComputerUseSetup.active") { [weak self] in
                self?.recheck()
            },
            distributedEvents.subscribe(Self.accessibilityTrustChanged, owner: "ComputerUseSetup.trust") { [weak self] in
                self?.recheck()
            },
        ]
    }

    /// Reads the grants again now (Settings opened, the step showed, the app came back).
    func recheck() {
        apply(inputs())
    }

    /// Opens the Privacy & Security list for `pane` in System Settings; the
    /// read on the app's next activation picks up the change.
    func open(_ pane: ComputerUsePermissionPane) {
        guard let url = Self.settingsURL(pane) else { return }
        openURL(url)
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
        case .disabledByPolicy, .unavailable, .starting: .none
        }
    }

    // MARK: Phase

    private func apply(_ inputs: Inputs) {
        generation &+= 1
        reading?.cancel()
        reading = nil
        retry.cancel()
        backoff.reset()
        if inputs.disabledByPolicy { return settle(.disabledByPolicy, running: nil) }
        guard inputs.enabled else { return settle(.off, running: nil) }
        switch inputs.helper {
        case .unavailable: settle(.unavailable, running: nil)
        // On, and ComputerUseHelperDaemon is starting the helper.
        case .off: settle(.starting, running: nil)
        case .running:
            guard let configuration = configuration() else { return settle(.starting, running: nil) }
            // Until the helper answers, the grants are being read, not off.
            if phase != .ready { phase = .starting }
            readGrants(configuration, generation: generation)
        }
    }

    /// A phase without a read: the grants are unknown, and the helper the
    /// grants would belong to is the one that would start.
    private func settle(_ phase: Phase, running: URL?) {
        self.phase = phase
        if phase != .ready { permissions = .none }
        resolve(running: running)
    }

    /// One read off main; its answer is one posted `visible` task. A started helper that does not answer yet is
    /// read again after a ``Backoff`` wait (``retry``), at most ``maximumRetries`` times.
    private func readGrants(_ configuration: AgentActivitySocketSource.Configuration, generation current: Int, attempt: Int = 0) {
        let read = read, mainWork = mainWork
        // task-owner: one read; a newer apply cancels it, and its generation drops a late answer.
        reading = work.task(.userVisible) { [weak self] in
            let result = await read(configuration)
            try Task.checkCancellation()
            await mainWork.apply(.visible, owner: "ComputerUseSetup.read") {
                self?.received(result, configuration, generation: current, attempt: attempt)
            }
        }
    }

    private func received(_ result: Read, _ configuration: AgentActivitySocketSource.Configuration, generation current: Int,
                          attempt: Int) {
        guard generation == current else { return }
        switch result {
        case .answered(let granted, let helper):
            phase = .ready
            permissions = granted
            resolve(running: helper)
        case .versionMismatch:
            setupLogger.error("cmux Computer Use helper answered permissions_status in another protocol version")
            settle(.versionMismatch, running: nil)
        case .noAnswer:
            // A helper that answered before keeps its rows until a read succeeds.
            if phase != .ready { settle(.starting, running: nil) }
            guard attempt < Self.maximumRetries else { return }
            retry.schedule(after: backoff.next()) { [weak self] in
                guard let self, generation == current else { return }
                readGrants(configuration, generation: current, attempt: attempt + 1)
            }
        }
    }

    /// Resolves the signed helper for `running` (or the installed one), once per running app: the signature
    /// check off main, its answer one posted `visible` task.
    private func resolve(running: URL?) {
        guard resolvedFor != .some(running) else { return }
        resolvedFor = .some(running)
        let resolveHelper = resolveHelper, mainWork = mainWork
        // task-owner: one signature check per helper identity; a newer one wins (resolvedFor).
        work.task(.userVisible) { [weak self] in
            let url = await resolveHelper(running)
            await mainWork.apply(.visible, owner: "ComputerUseSetup.helper") {
                self?.resolved(url, for: running)
            }
        }
    }

    private func resolved(_ url: URL?, for running: URL?) {
        guard resolvedFor == .some(running) else { return }
        helperAppURL = url
        helperAppIcon = nil
        guard let url, let queries else { return }
        queries.value(WorkspaceQuery<NSImage>.fileIcon(atPath: url.path, side: 32), priority: .userVisible) { [weak self] icon in
            guard let self, helperAppURL == url else { return }
            helperAppIcon = icon
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

    /// The Developer ID signed helper for `running`, else the installed one that would start: signature
    /// checks of each candidate (kept per version of it), so they run on `lanes`' system lane.
    nonisolated static func signedHelper(_ running: URL?, on lanes: any MayBlockRunner) async -> URL? {
        try? await lanes.runSystem(.userVisible) {
            CuaHelperIdentity().resolve(running: running,
                                        installed: CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild))
                .helperURL
        }
    }
}

extension ComputerUseSetup {
    /// The App's setup: `computerUse.enabled`, `DisabledFeatures` and the
    /// helper this app runs (`ComputerUseHelperDaemon.shared`).
    static func app(services: AppServices) -> ComputerUseSetup {
        let helper = ComputerUseHelperDaemon.shared
        let work = services.work
        let setup = ComputerUseSetup(
            inputs: { [weak services] in
                Inputs(disabledByPolicy: services?.registry.disabledFeatures.contains(.computerUse) ?? true,
                       enabled: services?.settings?.snapshot.computerUse.enabled ?? false,
                       helper: helper.state)
            },
            configuration: { helper.configuration },
            resolveHelper: { await ComputerUseSetup.signedHelper($0, on: work) },
            enableSetting: { [weak services] in
                guard let settings = services?.settings else { return }
                let writer = SettingWriter.currentRun()
                // task-owner: one settings write, the person's click; the helper start follows the setting.
                work.task(.userBlocking) {
                    do { try await settings.setSetting(at: ComputerUseSettings.enabledPath, to: .bool(true), by: writer) } catch {
                        setupLogger.error("Computer Use could not be turned on: \(String(describing: error), privacy: .public)")
                    }
                }
            },
            appEvents: services.appEvents,
            // raw-observer-allow: the app's one fan-out of distributed notices (Accessibility trust), one observer per name for the whole app
            distributedEvents: AppEvents(center: DistributedNotificationCenter.default(), observerLedger: .shared),
            deadlines: services.mainDeadlines, work: work, queries: services.workspaceQueries)
        setup.start()
        return setup
    }
}

extension ComputerUseSetup {
    /// The Settings page's Computer Use card (`cmux.settings.host.lists`
    /// `computer_use`): live through `cmux.settings.host.changed`, since the
    /// host lists read this observable model. Grants are null while unknown.
    var pageJSON: CmuxNextSettings.JSONValue {
        let known = phase == .ready
        return [
            "phase": .string(phase.rawValue),
            "accessibility": known ? .bool(permissions.accessibility) : .null,
            "screen_recording": known ? .bool(permissions.screenRecording) : .null,
            "helper": helperAppURL.map { .string($0.deletingPathExtension().lastPathComponent) } ?? .null,
        ]
    }
}

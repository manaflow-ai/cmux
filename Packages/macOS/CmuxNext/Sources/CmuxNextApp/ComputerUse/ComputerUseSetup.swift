import AppKit
import CmuxNextAgentActivity
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

private let setupLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

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

    @ObservationIgnored private let inputs: @MainActor () -> Inputs
    @ObservationIgnored private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    @ObservationIgnored private let read: @Sendable (AgentActivitySocketSource.Configuration) async -> Read
    @ObservationIgnored private let resolveHelper: @Sendable (URL?) async -> URL?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let enableSetting: @MainActor () -> Void
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private let distributed: NotificationCenter
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resolvedFor: URL??
    /// Reads after a helper start that has not answered yet.
    static let maximumRetries = 6

    /// macOS posts this (distributed) when any process's Accessibility trust changes.
    static let accessibilityTrustChanged = Notification.Name("com.apple.accessibility.api")

    init(inputs: @escaping @MainActor () -> Inputs,
         configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
         read: @escaping @Sendable (AgentActivitySocketSource.Configuration) async -> Read = { await ComputerUseSetup.socketRead($0) },
         resolveHelper: @escaping @Sendable (URL?) async -> URL? = ComputerUseSetup.signedHelper,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         enableSetting: @escaping @MainActor () -> Void = {},
         notifications: NotificationCenter = .default,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.inputs = inputs
        self.configuration = configuration
        self.read = read
        self.resolveHelper = resolveHelper
        self.openURL = openURL
        self.enableSetting = enableSetting
        self.notifications = notifications
        self.distributed = distributed
        self.clock = clock
    }

    isolated deinit {
        observation?.cancel()
        reading?.cancel()
        for observer in observers {
            notifications.removeObserver(observer)
            distributed.removeObserver(observer)
        }
    }

    /// Follows the inputs and the recheck events for the app's life. Idempotent.
    func start() {
        guard observation == nil else { return }
        let inputs = inputs
        observation = Task { [weak self] in
            for await value in Observations({ inputs() }) {
                guard let self else { return }
                apply(value)
            }
        }
        // The person comes back from System Settings: the grant may have changed.
        observers.append(notifications.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            // crash-allow: the observer runs on the main queue (queue: .main), so the main actor holds.
            MainActor.assumeIsolated { self?.recheck() }
        })
        observers.append(distributed.addObserver(forName: Self.accessibilityTrustChanged, object: nil,
                                                 queue: .main) { [weak self] _ in
            // crash-allow: the observer runs on the main queue (queue: .main), so the main actor holds.
            MainActor.assumeIsolated { self?.recheck() }
        })
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
        if inputs.disabledByPolicy { return settle(.disabledByPolicy, running: nil) }
        guard inputs.enabled else { return settle(.off, running: nil) }
        switch inputs.helper {
        case .unavailable: settle(.unavailable, running: nil)
        // On, and ComputerUseHelperDaemon is starting the helper.
        case .off: settle(.starting, running: nil)
        case .running:
            guard let configuration = configuration() else { return settle(.starting, running: nil) }
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

    private func readGrants(_ configuration: AgentActivitySocketSource.Configuration, generation current: Int) {
        let read = read
        let clock = clock
        // task-owner: one read (plus bounded retries while a started helper is not up yet); a newer apply cancels it.
        reading = Task { [weak self] in
            var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(4))
            for attempt in 0...Self.maximumRetries {
                let result = await read(configuration)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                switch result {
                case .answered(let granted, let helper):
                    phase = .ready
                    permissions = granted
                    resolve(running: helper)
                    return
                case .versionMismatch:
                    setupLogger.error("cmux Computer Use helper answered permissions_status in another protocol version")
                    settle(.versionMismatch, running: nil)
                    return
                case .noAnswer:
                    // A helper that answered before keeps its rows until a read succeeds.
                    if phase != .ready { settle(.starting, running: nil) }
                    guard attempt < Self.maximumRetries else { return }
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

    /// The Developer ID signed helper for `running`, else the installed one that would start.
    @concurrent nonisolated static func signedHelper(_ running: URL?) async -> URL? {
        CuaHelperIdentity().resolve(running: running,
                                    installed: CuaHelperIdentity.installedCandidates(isDevBuild: ComputerUseHelperDaemon.isDevBuild))
            .helperURL
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
                       helper: helper.state)
            },
            configuration: { helper.configuration },
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

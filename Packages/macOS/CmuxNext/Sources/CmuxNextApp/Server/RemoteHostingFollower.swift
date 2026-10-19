import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation
import Observation
import os

/// Applies Settings > Accounts > Remote Hosting (`remoteHosting.enabled`;
/// plans/cmux-next/remote-hosts.md 9): on runs the bundled
/// `cmux host enable --no-spawn --session <the app's daemon session>`, off runs
/// `cmux host disable`; unset leaves hosting as the CLI set it. The listener,
/// its service and its admission rules are the CLI's (Rust); this type runs it
/// and keeps the one-line status of `cmux host status --remote --json` for the
/// Settings page. It reads at launch, after each change and when the app becomes
/// active, never on a timer. An administrator's `DisabledFeatures: remoteHosts`
/// turns hosting off and wins over the setting.
///
/// Hosting is one per user (`~/.cmux/host`), so only an owner build (release or NIGHTLY,
/// the builds with the default state) changes it, and only for its own session: it never
/// takes over or turns off hosting another build set up. Every other build (a tagged DEV,
/// RC, staging) shows the status and never runs enable or disable.
@MainActor
@Observable
final class RemoteHostingFollower {
    /// What `cmux host status --remote --json` says (the fields the app shows or compares).
    struct Status: Equatable {
        var enabled: Bool
        var serving: Bool
        var starting: Bool
        var spawn: Bool
        var session: String?
        var name: String?
        /// The private network's state on this Mac (`Running` when it is up).
        var network: String?
    }

    /// One CLI run: exit status and stdout, or nil when the CLI could not run.
    typealias Run = @MainActor ([String]) async -> (status: Int32, stdout: Data)?

    @ObservationIgnored private let run: Run
    /// The app's own daemon session (the one the listener serves).
    @ObservationIgnored private let session: String
    @ObservationIgnored private let available: Bool
    /// This build may change hosting (see the type's note).
    let owner: Bool
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.remote-hosting")
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var working: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    /// The setting's value (nil: unset).
    @ObservationIgnored private var desired: Bool?
    /// The key's last raw value, to tell its own edits from other settings edits.
    @ObservationIgnored private var lastRaw: Bool??

    private(set) var status: Status?
    /// The last enable or disable failed.
    private(set) var failed = false
    private(set) var policyDisabled = false

    init(session: String, available: Bool, owner: Bool, run: @escaping Run) {
        self.session = session
        self.available = available
        self.owner = owner
        self.run = run
    }

    /// Follows the setting from now on (once).
    func start(settings: SettingsController) {
        guard observers.isEmpty else { return }
        observers.append(Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await wanted in ObservationStream({ settings.snapshot.sessions.remoteHosting }) {
                guard let self else { return }
                // Any settings edit wakes the stream; only a change of this key's raw value
                // (or the first value) acts. Compared with the last raw value, not `desired`:
                // after a reset `desired` is false while the raw value stays nil.
                let first = lastRaw == nil
                guard first || lastRaw != .some(wanted) else { continue }
                // A reset (set, then unset) means off, as the toggle shows; unset from
                // the start leaves hosting as the CLI set it.
                desired = !first && wanted == nil ? false : wanted
                lastRaw = .some(wanted)
                sync()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.sync()
            }
        })
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        working?.cancel()
        working = nil
    }

    /// `DisabledFeatures: remoteHosts`: hosting stops and the setting is ignored until it is lifted.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        sync()
    }

    /// The Settings page's one line under Machines; nil while nothing is known.
    var statusLine: String? {
        guard available else { return nil }
        if policyDisabled { return RefusalStrings.turnedOffByOrganization }
        if let status, status.network != "Running" { return RemoteHostStrings.networkOff }
        if failed { return RemoteHostStrings.changeFailed }
        guard let status else { return nil }
        if !status.enabled { return RemoteHostStrings.off }
        if status.session != session { return RemoteHostStrings.otherBuild }
        if status.serving { return RemoteHostStrings.serving(status.name ?? "") }
        return status.starting ? RemoteHostStrings.starting : RemoteHostStrings.notServing
    }

    /// The Settings page's note for a build that may not change hosting; nil for an owner.
    var readOnlyNote: String? {
        available && !owner ? RemoteHostStrings.readOnly : nil
    }

    /// Reads the status and applies the setting once; a call during a run runs once more after it.
    private func sync() {
        guard available else { return }
        guard working == nil else {
            syncAgain = true
            return
        }
        working = Task { [weak self] in
            await self?.syncOnce()
            guard let self, !Task.isCancelled else { return }
            working = nil
            if syncAgain {
                syncAgain = false
                sync()
            }
        }
    }

    private func syncOnce() async {
        let current = await readStatus()
        guard !Task.isCancelled else { return }
        status = current
        // Only an owner build changes hosting; the others only read it.
        let want: Bool? = !owner ? nil : policyDisabled ? false : desired
        guard let want, let current else {
            failed = false
            return
        }
        let arguments: [String]
        if want {
            // Already serving this app's session the way the app needs: nothing to redo
            // (enable restarts the listener, which would drop open connections). A listener
            // that is configured but not running is started again by enable.
            if current.enabled, current.session == session, !current.spawn, current.serving || current.starting {
                failed = false
                return
            }
            // Hosting another build's session: never taken over (status says so).
            if current.enabled, current.session != session {
                failed = false
                return
            }
            arguments = ["host", "enable", "--no-spawn", "--session", session, "--json"]
        } else {
            // Off, or hosting another build's session: nothing of this build's to turn off.
            guard current.enabled, current.session == session else {
                failed = false
                return
            }
            arguments = ["host", "disable", "--json"]
        }
        let result = await run(arguments)
        guard !Task.isCancelled else { return }
        failed = result?.status != 0
        if failed { logger.error("remote hosting: `cmux \(arguments.prefix(2).joined(separator: " "), privacy: .public)` failed") }
        status = await readStatus() ?? status
    }

    private func readStatus() async -> Status? {
        guard let result = await run(["host", "status", "--remote", "--json"]), result.status == 0 else { return nil }
        return Self.parseStatus(result.stdout)
    }

    nonisolated static func parseStatus(_ data: Data) -> Status? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabled = object["enabled"] as? Bool else { return nil }
        return Status(enabled: enabled, serving: object["serving"] as? Bool ?? false, starting: object["starting"] as? Bool ?? false,
                      spawn: object["spawn"] as? Bool ?? true, session: object["session"] as? String, name: object["name"] as? String,
                      network: object["tailnet"] as? String)
    }
}

extension RemoteHostingFollower {
    /// The app's follower: the bundle's own `cmux`, the app's daemon session. The CLI runs
    /// with the app daemon's socket environment (`TMPDIR` the per-user temp directory, no
    /// `XDG_RUNTIME_DIR`; ``DaemonLauncher/ensureEnvironment()``), so `--session` names the
    /// socket the daemon and the launchd listener use, whatever the app was launched with.
    static func app(services: AppServices) -> RemoteHostingFollower {
        let cli = RemoteHostSource.bundledCLI()
        let kind = services.environment.launch.build.kind
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = nil
        environment["TMPDIR"] = DaemonLauncher.userTemporaryDirectory().path
        return RemoteHostingFollower(session: services.environment.daemonSession, available: cli != nil,
                                     owner: kind == .release || kind == .nightly, run: { [environment] arguments in
            guard let cli,
                  let result = try? await ProcessRunner.run(executable: cli, arguments: arguments, environment: environment,
                                                            timeout: .seconds(30), clock: ContinuousClock()) else { return nil }
            return (result.status, result.stdout)
        })
    }
}

import CmuxNextWakeups
import Foundation

/// Live background updates (`updates.daemon`, off by default; Leo, 2026-11-22: "i wonder how many we can
/// actually just ship and not even need the user to restart to update, tbh."). On a NIGHTLY or tip app
/// (``WebUpdater/takesUpdates(_:)``) with the setting at Every Merge, every ``interval`` while cmux is idle
/// it runs the bundled `cmux --json app try channel`. That command decides everything (cmux-tui
/// `app try channel`): it reads the signed mac-live channel, checks this app's commit can take it and that
/// it is newer, swaps `Contents/Resources/bin`, hands the terminal daemon over (the app's reconnect starts
/// the new one, terminals kept) and rolls back on failure. Swift only triggers it and logs its answer.
///
/// Idle is Update When Idle's rule (cmux-window-rules `update_idle`, through the App's ``UpdateIdleGate``):
/// no running agent turn, no unsent draft and input quiet ``idleMinutes``. One run at a time, off the main
/// thread, at most ``runBound``. Debug builds never run it.
@MainActor
final class DaemonLiveUpdates {
    /// Time between looks.
    nonisolated static let interval: Duration = .seconds(120)
    /// The longest one run may take before it gets SIGTERM (then SIGKILL).
    nonisolated static let runBound: Duration = .seconds(600)
    /// Input quiet this long, in minutes, before a run.
    nonisolated static let idleMinutes = 1.0

    /// `hold(idleMinutes)`: why a run waits now (a cmux-window-rules hold reason), nil to run.
    typealias Hold = @MainActor (_ idleMinutes: Double) -> String?

    private let timer = DemandTimer(owner: "daemon-live-updates")
    private let cli: URL
    private let log: UpdateLogBuffer
    private let hold: Hold
    private var enabled = false
    private var running = false
    /// The hold at the last look, so a hold that lasts logs once.
    private var lastHold: String?

    /// Nil when `bundle` takes no live daemon updates (``isAvailable(_:)``) or has no resources folder.
    /// The updater makes it with its idle gate (``UpdaterService/useIdleGate(_:)``), before the settings apply.
    init?(bundle: Bundle, log: UpdateLogBuffer, hold: @escaping Hold) {
        guard Self.isAvailable(bundle), let resources = bundle.resourceURL else { return nil }
        cli = resources.appending(path: "bin/cmux", directoryHint: .notDirectory)
        self.log = log
        self.hold = hold
    }

    /// Whether `bundle` may take live daemon updates: NIGHTLY and the tip app, never a Debug build.
    nonisolated static func isAvailable(_ bundle: Bundle) -> Bool {
        #if DEBUG
        return false
        #else
        return WebUpdater.takesUpdates(UpdateBuildIdentity(infoDictionary: bundle.infoDictionary ?? [:]))
        #endif
    }

    /// `updates.daemon`: Every Merge (`enabled`) looks every ``interval``; Off stops looking (a run already
    /// started ends by itself).
    func follow(enabled on: Bool) {
        guard on != enabled else { return }
        enabled = on
        log.append("daemon live updates: \(on ? "every merge" : "off")")
        if on { schedule() } else { timer.cancel() }
    }

    private func schedule() {
        timer.schedule(after: Self.interval) { [weak self] in await self?.look() }
    }

    private func look() async {
        guard enabled else { return }
        guard !running else { return schedule() }
        let reason = hold(Self.idleMinutes)
        if reason != lastHold {
            lastHold = reason
            if let reason { log.append("daemon live updates: waiting (\(reason))") }
        }
        guard reason == nil else { return schedule() }
        running = true
        let result = await Self.run(cli)
        running = false
        log.append("daemon live updates: \(result)")
        if enabled { schedule() }
    }

    /// Runs `cli --json app try channel` and answers its exit and JSON, one line. Off the main actor: the
    /// spawn and the wait never touch the main thread. A cancel never stops it half way through a swap.
    @concurrent
    nonisolated static func run(_ cli: URL) async -> String {
        let request = ProcessRequest(cli, ["--json", "app", "try", "channel"], errorOutput: .separate,
                                     timeout: runBound, onCancel: .finish)
        do {
            let outcome = try await AsyncProcess().run(request)
            let output = summary(outcome.output)
            let error = summary(outcome.errorOutput)
            let ending = outcome.exited ? "exit \(outcome.status)" : "signal \(outcome.status)"
            return error.isEmpty ? "\(ending) \(output)" : "\(ending) \(output) stderr: \(error)"
        } catch {
            return "failed: \(error)"
        }
    }

    /// `data` as one trimmed line of at most 2000 characters.
    nonisolated static func summary(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.count > 2000 ? String(text.prefix(2000)) + "..." : text
    }
}

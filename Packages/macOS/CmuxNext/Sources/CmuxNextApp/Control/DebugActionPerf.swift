#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextDesign

/// `debug.action_perf` (DEBUG builds): per action handler run, from any entrypoint (a key,
/// `action.run`, a menu, the palette), when it began (`began`, `CACurrentMediaTime`, the same
/// clock as `CLOCK_UPTIME_RAW` and an `NSEvent` timestamp), how long the handler took on the main
/// thread (`run_ms`, nested runs included) and when the Core Animation commit that carries its
/// synchronous changes ran (`commit`, ``CommitProbe``: after AppKit's layout and display, before the
/// window-server transaction; `commit_end` an upper bound of that commit's end).
///
/// scripts/cmux-next/every-action-sweep.py sends the input at a known client time and reads the rows:
/// input to `began` is the wait for the main thread, `began` to `commit` the action's own turn.
/// Records only between `start` and `stop` (hooks the registry then, never otherwise); a run nested in
/// another run joins the outer row. `read` returns the rows and keeps them, `drain` returns and clears.
/// `now` is the app's clock, for a client to check it reads the same clock.
@MainActor
final class DebugActionPerf {
    private struct Row {
        var action: String, origin: String, began: CFTimeInterval
        var ran: CFTimeInterval?, commit: (CFTimeInterval, CFTimeInterval)?
    }

    private weak var registry: ActionRegistry?
    private var windows: () -> [NSWindow] = { [] }
    private var recording = false
    private var hooked = false
    private var depth = 0
    private var rows: [Row] = []
    private var probes: [ObjectIdentifier: CommitProbe] = [:]
    private var priorScope: (@MainActor (ActionInvocation, () -> Void) -> Void)?
    private static let capacity = 4_096

    func install(registry: ActionRegistry, windows: @escaping () -> [NSWindow]) {
        self.registry = registry
        self.windows = windows
    }

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            rows.removeAll(keepingCapacity: true)
            hook()
            recording = true
        case "stop":
            let report = report(clear: true)
            recording = false
            unhook()
            return report
        case "drain":
            return report(clear: true)
        default:
            break
        }
        return report(clear: false)
    }

    private func hook() {
        guard !hooked, let registry else { return }
        hooked = true
        registry.willRunObservers.append { [weak self] id, origin in self?.willRun(id, origin) }
        priorScope = registry.invocationScope
        registry.invocationScope = { [weak self] invocation, body in
            let outer = self?.depth == 0
            self?.depth += 1
            if let prior = self?.priorScope { prior(invocation, body) } else { body() }
            self?.depth -= 1
            if outer { self?.didRun() }
        }
    }

    /// Recording stops; the observer stays (one closure, a no-op while not recording) since the
    /// registry's observer list has no removal, and the run scope goes back to the App's.
    private func unhook() {
        guard hooked, let registry else { return }
        registry.invocationScope = priorScope
        priorScope = nil
        hooked = false
        depth = 0
        for probe in probes.values { probe.remove() }
        probes = [:]
    }

    private func willRun(_ id: ActionID, _ origin: ActionOrigin) {
        guard recording, hooked, depth == 0, rows.count < Self.capacity else { return }
        rows.append(Row(action: id.rawValue, origin: origin.rawValue, began: CACurrentMediaTime()))
        // The transaction open now carries the handler's synchronous changes: its commit is the action's frame.
        for window in windows() where window.isVisible {
            guard let host = window.contentView?.layer else { continue }
            let key = ObjectIdentifier(window)
            let probe = probes[key] ?? CommitProbe { [weak self] displayed, ended in self?.committed(displayed, ended) }
            probes[key] = probe
            probe.mark(in: host)
        }
    }

    private func didRun() {
        guard recording, let last = rows.indices.last, rows[last].ran == nil else { return }
        rows[last].ran = CACurrentMediaTime()
    }

    private func committed(_ displayed: CFTimeInterval, _ ended: CFTimeInterval) {
        for index in rows.indices where rows[index].commit == nil && rows[index].began <= displayed {
            rows[index].commit = (displayed, ended)
        }
    }

    private func report(clear: Bool) -> JSONValue {
        let list: [JSONValue] = rows.map { row in
            var members: [String: JSONValue] = ["action": .string(row.action), "origin": .string(row.origin), "began": .number(row.began)]
            if let ran = row.ran { members["run_ms"] = .number((ran - row.began) * 1_000) }
            if let commit = row.commit {
                members["commit"] = .number(commit.0)
                members["commit_end"] = .number(commit.1)
                members["commit_ms"] = .number((commit.0 - row.began) * 1_000)
            }
            return .object(members)
        }
        if clear { rows.removeAll(keepingCapacity: true) }
        return .object(["recording": .bool(recording), "now": .number(CACurrentMediaTime()), "runs": .array(list)])
    }
}
#endif

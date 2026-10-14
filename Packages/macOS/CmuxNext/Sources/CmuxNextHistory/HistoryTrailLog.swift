public import Foundation
import os

/// The failure log of the location trail (cx-hnmbt.14): one line per settled focus the trail
/// skips or records, per step the app reports to the daemon (`history.trail.record`), and per
/// daemon reply or refusal. Subsystem `com.cmuxterm.app.next`, category `trail`; read it with
/// `log stream --level debug --predicate 'category == "trail"'`. Titles and paths stay private.
public nonisolated struct HistoryTrailLog: Sendable {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "trail")

    public init() {}

    /// A settled focus the trail did not record, and why.
    public func skipped(_ reason: String, window: String, workspace: String?) {
        logger.info("settle skipped: \(reason, privacy: .public) window=\(window, privacy: .public) workspace=\(workspace ?? "-", privacy: .public)")
    }

    /// The app's own step rules ran on a settled location (`changed`: the trail changed).
    public func ruled(_ location: HistoryLocation, rule: String, changed: Bool) {
        logger.info("step \(rule, privacy: .public) changed=\(changed, privacy: .public) tab=\(location.key.tab, privacy: .public) workspace=\(location.workspace, privacy: .public) incognito=\(location.isIncognito, privacy: .public) title=\(location.title, privacy: .private)")
    }

    /// A step was kept for later: no daemon serves the trail now.
    public func unsent(_ location: HistoryLocation) {
        logger.notice("report held (no daemon history): tab=\(location.key.tab, privacy: .public)")
    }

    /// A step went to the daemon.
    public func reported(_ location: HistoryLocation, atMs: Int64, steps: String, jump: Bool) {
        logger.info("report sent: tab=\(location.key.tab, privacy: .public) at_ms=\(atMs, privacy: .public) steps=\(steps, privacy: .public) jump=\(jump, privacy: .public)")
    }

    /// The daemon answered a step: the entry it landed in and whether its trail changed.
    public func replied(_ location: HistoryLocation, id: String?, recorded: Bool?) {
        logger.info("report reply: tab=\(location.key.tab, privacy: .public) id=\(id ?? "-", privacy: .public) recorded=\(recorded.map(String.init) ?? "-", privacy: .public)")
    }

    /// The daemon refused a step, or it never reached the daemon.
    public func failed(_ location: HistoryLocation, _ error: any Error) {
        logger.error("report failed: tab=\(location.key.tab, privacy: .public) error=\(String(describing: error), privacy: .public)")
    }

    /// The app read the daemon's trail (`adopt` at connect, `reread` after history-changed).
    public func read(_ what: String, steps: Int, local: Int, removed: Int) {
        logger.info("trail \(what, privacy: .public): daemon steps=\(steps, privacy: .public) local entries=\(local, privacy: .public) removed=\(removed, privacy: .public)")
    }
}

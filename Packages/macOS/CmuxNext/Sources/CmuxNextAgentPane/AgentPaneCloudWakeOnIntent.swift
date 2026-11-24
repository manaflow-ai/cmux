import CmuxNextWakeups
import Foundation
import os

/// Wake on intent's App side (`cloudMachine.wakeHint`): forwards each raw signal with the facts the
/// App's models hold, runs the resume or the re-pause the rules answer, and logs each hint wake's
/// outcome. Every decision (which signal counts, debounce, cap, the no-input bound) is Rust's:
/// `cloud_handler_wake_*` (cmux-cloud-handlers `wake_hint`), whose ledger lives in the app FFI. The
/// App sets ``Port``; the hidden setting `cloud.wakeOnIntent` is one of its facts (default off).
@MainActor
public final class AgentPaneCloudWakeOnIntent {
    public struct Port {
        /// One rules op; nil when the FFI lacks it (an older app library): no wake.
        public var ask: @MainActor (_ op: String, _ request: [String: Any]) -> [String: Any]?
        /// The hint's facts for machine `id`: `enabled`, `allowed`, `loaded`, `status`.
        public var facts: @MainActor (_ id: String) -> [String: Any]
        /// Script-originated resume and pause.
        public var resume: @MainActor (_ id: String) async -> Bool
        public var pause: @MainActor (_ id: String) async -> Void

        public init(ask: @escaping @MainActor (String, [String: Any]) -> [String: Any]?, facts: @escaping @MainActor (String) -> [String: Any],
                    resume: @escaping @MainActor (String) async -> Bool, pause: @escaping @MainActor (String) async -> Void) {
            self.ask = ask
            self.facts = facts
            self.resume = resume
            self.pause = pause
        }
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud.wake-hint")
    private let port: Port
    private var timers: [String: DemandTimer] = [:]

    public init(port: Port) {
        self.port = port
    }

    /// One hint; true when it resumed the machine.
    public func hint(machine id: String, signal: String, version: Int) async -> Bool {
        var request = port.facts(id)
        request["v"] = version
        request["machine"] = id
        request["signal"] = signal
        guard port.ask("cloud_handler_wake_hint", request)?["resume"] as? Bool == true else { return false }
        let ok = await port.resume(id)
        logger.info("wake hint \(signal, privacy: .public) resumed \(id, privacy: .public): \(ok)")
        if let after = port.ask("cloud_handler_wake_resumed", ["machine": id, "ok": ok])?["checkAfterMs"] as? Int { schedule(id, after: after) }
        return ok
    }

    /// The person used machine `id` (typed, attached, opened): a hint wake it had is `used`.
    public func input(machine id: String) {
        guard let outcome = port.ask("cloud_handler_wake_input", ["machine": id])?["outcome"] as? [String: Any] else { return }
        timers.removeValue(forKey: id)?.cancel()
        log(id, outcome)
    }

    private func schedule(_ id: String, after ms: Int) {
        let timer = timers[id] ?? DemandTimer(owner: "cloud.wakeHint")
        timers[id] = timer
        timer.schedule(after: .milliseconds(ms)) { @MainActor [weak self] in await self?.check(id) }
    }

    private func check(_ id: String) async {
        var request: [String: Any] = ["machine": id]
        if let status = port.facts(id)["status"] { request["status"] = status }
        guard let answer = port.ask("cloud_handler_wake_idle", request) else { return }
        switch answer["do"] as? String {
        case "wait":
            if let after = answer["checkAfterMs"] as? Int { schedule(id, after: after) }
        case "pause":
            timers[id] = nil
            if let outcome = answer["outcome"] as? [String: Any] { log(id, outcome) }
            await port.pause(id)
        default:
            timers[id] = nil
        }
    }

    /// The wake log line: `used` with the lead from resume to input, or `false` with the awake ms.
    private func log(_ id: String, _ outcome: [String: Any]) {
        let tag = outcome["tag"] as? String ?? "?", signal = outcome["signal"] as? String ?? "?"
        let ms = outcome["awakeMs"] as? Int ?? outcome["leadMs"] as? Int ?? 0
        logger.info("wake hint outcome machine=\(id, privacy: .public) tag=\(tag, privacy: .public) signal=\(signal, privacy: .public) ms=\(ms)")
    }
}

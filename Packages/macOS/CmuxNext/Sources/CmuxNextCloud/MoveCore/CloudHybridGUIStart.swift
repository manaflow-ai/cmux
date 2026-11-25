public import CmuxNextDaemon
public import Foundation
public import os
import CmuxNextWakeups

/// The composer's Cloud send as a hybrid start: its first turn runs on this Mac while the Cloud
/// machine boots, then the chat moves there with the app's own Move (fenced, cmux#55785). Every
/// decision is cmux-cloud-start-core `hybrid_gui` (FFI `cloud_hybrid_gui_start`); this only passes
/// the facts, logs the probe line (`cloud hybrid gui start: here` or `... off <reason>`) and runs
/// `cmux cloud hybrid-begin SESSION new` once the chat here has its session. Kill switches:
/// `CMUX_HYBRID_START=0`, `CMUX_GUI_HYBRID_START=0` (read by the FFI).
public nonisolated struct CloudHybridGUIStart {
    public nonisolated init() {}
    /// What the app knows of its Cloud send (cmux-cloud-start-core `hybrid_gui::Send`).
    public struct Send: Sendable {
        public var plan: String?, signedIn: Bool, cloudDisabled: Bool
        public var folder: Bool, repository: Bool, team: Bool, replacesChat: Bool, environment: Bool
        public var harness: String?
        /// This Mac's acpmux `_acpmux/harnesses` answer, JSON; nil: it did not answer.
        public var catalog: Data?
        public init(plan: String?, signedIn: Bool, cloudDisabled: Bool, folder: Bool, repository: Bool, team: Bool,
                    replacesChat: Bool, environment: Bool, harness: String?, catalog: Data?) {
            self.plan = plan; self.signedIn = signedIn; self.cloudDisabled = cloudDisabled; self.folder = folder
            self.repository = repository; self.team = team; self.replacesChat = replacesChat
            self.environment = environment; self.harness = harness; self.catalog = catalog
        }
    }

    /// Whether the send runs its first turn here; logs Rust's probe line either way.
    public static func runsHere(_ send: Send, logger: Logger) -> Bool {
        var request: [String: Any] = [
            "account": ["plan": send.plan as Any, "signedIn": send.signedIn, "cloudDisabled": send.cloudDisabled],
            "folder": send.folder, "repository": send.repository, "team": send.team,
            "replacesChat": send.replacesChat, "environment": send.environment,
        ]
        if let harness = send.harness { request["harness"] = harness }
        if let catalog = send.catalog, let object = try? JSONSerialization.jsonObject(with: catalog) { request["catalog"] = object }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = CloudStartCore().callData("cloud_hybrid_gui_start", data),
              let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            logger.notice("cloud hybrid gui start: unanswered")
            return false
        }
        logger.notice("\((answer["probe"] as? String) ?? "cloud hybrid gui start: unanswered", privacy: .public)")
        return answer["here"] as? Bool == true
    }

    /// Begins the machine and the move for `session`, the chat here: the CLI's own detached driver.
    public static func begin(session: String, cli: URL, logger: Logger) {
        // task-owner: fire and forget; the CLI returns once its detached driver is spawned (30 s bound)
        Task(priority: WorkPriority.bestEffort.taskPriority) {
            let result = try? await ProcessRunner.run(executable: cli, arguments: ["cloud", "hybrid-begin", session, "new"],
                                                      environment: nil, timeout: .seconds(30), clock: ContinuousClock())
            let said = result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "not run"
            logger.notice("cloud hybrid gui start: begun \(session, privacy: .public) status \(result?.status ?? -1) \(said, privacy: .public)")
        }
    }
}

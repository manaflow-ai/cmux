public import Foundation
import os

/// `cloud.forkFirst {sessionId, permissionId, optionId, machine, clientKey}`: "Fork first" on a risky
/// step's permission card in a Cloud chat (RFD 0163 row 25, acpmux `fork_risky.rs`, behind
/// `cloud.autoCloud`). The App forks the chat's Cloud machine with the person's own token: a fork is
/// the machine creator's call, and a Cloud machine holds no creator credential, so acpmux there
/// never forks. The person's click pays for the allow's ticket before the fork starts; the ticket's
/// clock starts again once the fork answers (a fork takes 30 to 60 s, longer than a ticket lives),
/// and the page sends the allow with it and `forkCheckpoint {machine, fork, forkMs}`.
public nonisolated struct AgentPaneForkFirst: Equatable, Sendable {
    public var sessionId: String
    public var permissionId: String
    public var optionId: String
    /// The machine the ask's offer names; the App forks it only when it is the pane's own.
    public var machine: String
    /// The offer's key (`risky-<permissionId>`): a retry answers the same copy, never a second one.
    public var clientKey: String

    public init?(params: [String: Any]?) {
        func id(_ key: String, _ pattern: String) -> String? {
            guard let value = params?[key] as? String,
                  value.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return value
        }
        guard let sessionId = id("sessionId", #"^[A-Za-z0-9_.:-]{1,128}$"#),
              let permissionId = id("permissionId", #"^[^\x00-\x1f]{1,256}$"#),
              let optionId = id("optionId", #"^[^\x00-\x1f]{1,256}$"#),
              let machine = id("machine", #"^[A-Za-z0-9_-]{1,64}$"#),
              let clientKey = id("clientKey", #"^[^\x00-\x1f]{1,128}$"#) else { return nil }
        self.sessionId = sessionId
        self.permissionId = permissionId
        self.optionId = optionId
        self.machine = machine
        self.clientKey = clientKey
    }

    /// The App's side: forks with `call` (the app server's `cloud.machine.fork`, the person's own
    /// credential; it answers the copy's id) while `still` holds before and after it (the offer's
    /// machine is the pane's Cloud machine), and answers `{fork, forkMs}`, `not_cloud` or `fork_failed`.
    @MainActor
    public func run(still: @MainActor () -> Bool, _ call: @MainActor () async throws -> String?) async -> [String: Any] {
        guard still() else { return AgentPaneReply.failure(code: "not_cloud", message: "not_cloud") }
        let started = ContinuousClock.now
        let copy: String?
        do { copy = try await call() } catch {
            Self.logger.error("fork before a risky step failed: \(String(describing: type(of: error)), privacy: .public)")
            return AgentPaneReply.failure(code: "fork_failed", message: "fork_failed")
        }
        let ms = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
        guard let copy, Self.isMachine(copy), copy != machine else { return AgentPaneReply.failure(code: "fork_failed", message: "fork_failed") }
        Self.logger.info("forked \(machine, privacy: .public) before a risky step: \(copy, privacy: .public) in \(ms) ms")
        guard still() else { return AgentPaneReply.failure(code: "not_cloud", message: "not_cloud") }
        return AgentPaneReply.success(["fork": copy, "forkMs": ms])
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.fork-first")

    static func isMachine(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }

    /// The allow this fork stands before, as `transport.gesture` reserves it.
    var intent: AgentPaneGestureIntent? {
        AgentPaneGestureIntent(gestureParams: ["intent": [
            "method": "_acpmux/permission_respond",
            "params": ["sessionId": sessionId, "permissionId": permissionId, "optionId": optionId],
        ]])
    }
}

extension AgentPaneModel {
    /// ``AgentPaneForkFirst``: only a chat on another machine, its own chat, on the person's own
    /// click on an allow the pane was shown. The App's answer is `{fork, forkMs}` or a refusal; the
    /// page gets it with the allow's ticket. A failed fork spends the ticket: the step still waits.
    func forkFirst(_ fork: AgentPaneForkFirst) async -> [String: Any] {
        guard let onCloudForkFirst, remoteChat, sessionId == nil || sessionId == fork.sessionId else {
            return Self.unsupported("cloud.forkFirst")
        }
        guard let intent = fork.intent else { return Self.transportFailure(.intentInvalid) }
        guard let ticket = transport.reserveGesture(intent, personOnly: true) else {
            return Self.transportFailure(.gestureRequired)
        }
        let reply = await onCloudForkFirst(fork)
        guard reply["ok"] as? Bool == true, var value = reply["value"] as? [String: Any],
              value["fork"] is String, value["forkMs"] is Int else {
            transport.gestures.drop(ticket)
            return reply["ok"] as? Bool == false ? reply : AgentPaneReply.failure(code: "fork_failed", message: "fork_failed")
        }
        guard transport.gestures.renew(ticket) else { return Self.transportFailure(.gestureRequired) }
        value["ticket"] = ticket
        return AgentPaneReply.success(value)
    }
}

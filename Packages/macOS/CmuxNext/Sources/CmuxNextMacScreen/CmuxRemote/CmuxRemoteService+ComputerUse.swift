// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
public import Observation
import os

private let computerUseLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// What the app knows of cmux Remote's Computer Use worker, from the host status it last read
/// (Computer Use Setup follows it).
@MainActor @Observable
public final class CmuxRemoteComputerUseState {
    /// This build embeds cmux Remote (``CmuxRemoteService/start``).
    public internal(set) var embedded = false
    /// The host's pid while one answers.
    public internal(set) var hostPID: pid_t?
    /// The Computer Use worker reported it could not start (`workers["computer-use"].state` "unavailable").
    public internal(set) var computerUseFailed = false
    /// Why, when it says.
    public internal(set) var failure: String?
    /// The worker's state as cmux Remote reports it (`off`, `starting`, `ready`, `unavailable`), and its pid.
    public internal(set) var workerState: String?
    public internal(set) var workerPID: pid_t?
    /// The saved approvals (`computer-use-approvals list`): app id to "always" or "never", sorted by id.
    public internal(set) var approvals: [(appID: String, decision: String)] = []

    nonisolated init() {}

    /// Takes the host's own status object (`remote-host-status`'s `host`, or a host call's answer).
    func take(host: [String: Any]?) {
        let pid = (host?["pid"] as? Int).map { pid_t($0) }
        if hostPID != pid { hostPID = pid }
        let worker = (host?["workers"] as? [String: Any])?["computer-use"] as? [String: Any]
        let failed = worker?["state"] as? String == "unavailable"
        if computerUseFailed != failed { computerUseFailed = failed }
        let reason = failed ? worker?["reason"] as? String : nil
        if failure != reason { failure = reason }
        let state = worker?["state"] as? String
        if workerState != state { workerState = state }
        let workerPID = (worker?["pid"] as? Int).map { pid_t($0) }
        if self.workerPID != workerPID { self.workerPID = workerPID }
    }

    /// Takes a `list` answer: `{"saved":{"always":[...],"never":[...]}}` (ids, or `{"app_id"|"id"}` objects).
    func take(approvals answer: [String: Any]?) {
        let saved = answer?["saved"] as? [String: Any] ?? answer ?? [:]
        func ids(_ key: String) -> [String] {
            (saved[key] as? [Any] ?? []).compactMap { entry in
                if let id = entry as? String { return id }
                let object = entry as? [String: Any]
                return (object?["app_id"] ?? object?["id"]) as? String
            }
        }
        let next = (ids("always").map { ($0, "always") } + ids("never").map { ($0, "never") }).sorted { $0.0 < $1.0 }
        if next.map(\.0) != approvals.map(\.appID) || next.map(\.1) != approvals.map(\.decision) {
            approvals = next.map { (appID: $0.0, decision: $0.1) }
        }
    }
}

/// The policy the app sends cmux Remote's Computer Use worker: the person's `computerUse.*`
/// (`ComputerUseSettings.policyConfigJSON()`) and the agent cursor's animation switches.
public struct CmuxRemoteComputerUsePolicy: Equatable, Sendable {
    public var policy: Data
    /// `ui.animations.enabled`, `ui.animations.cursor` and `ui.animationSpeed` not "off".
    public var cursorAnimates: Bool
    /// `ui.animationSpeed`'s pace (2: twice as fast).
    public var cursorSpeed: Double

    public init(policy: Data, cursorAnimates: Bool, cursorSpeed: Double) {
        self.policy = policy
        self.cursorAnimates = cursorAnimates
        self.cursorSpeed = cursorSpeed
    }

    /// The `computer-use-config` object: the PolicyConfig plus `cursorMotion` (the engine ignores
    /// keys it does not know; cmux Remote's worker reads it for the cursor).
    var config: CmuxNextDaemon.JSONValue? {
        guard let object = try? JSONDecoder().decode(CmuxNextDaemon.JSONValue.self, from: policy),
              case .object(var fields) = object else { return nil }
        fields["cursorMotion"] = .object(["enabled": .bool(cursorAnimates), "speed": .number(cursorSpeed)])
        return .object(fields)
    }
}

extension CmuxRemoteService {
    /// Sends the policy to cmux Remote (it starts, restarts or stops its Computer Use worker from it).
    public func applyComputerUse(_ policy: CmuxRemoteComputerUsePolicy) async {
        guard let config = policy.config else { return }
        do {
            // The daemon checks the policy and hands it to cmux Remote (the verified app's only).
            let answer = try await daemonRequest(ComputerUseConfigRequest(config: config))
            computerUse.take(host: Self.object(answer))
        } catch {
            computerUseLogger.notice("cmux Remote Computer Use config refused: \(String(describing: error), privacy: .public)")
        }
    }

    /// Follows the policy (read inside an observation) for the app's life, from the first settings load on.
    public func followComputerUse(_ policy: @escaping @MainActor () -> CmuxRemoteComputerUsePolicy?) {
        // task-owner: lives with the app; follows the settings and the daemon.
        Task { [weak self] in
            // The settings load first (`follow` sets the switches then): no policy is sent before it.
            _ = await self?.waitAvailable()
            for await next in ObservationStream(policy) {
                guard let self, let next else { continue }
                guard await waitAvailable() else { continue }
                await applyComputerUse(next)
            }
        }
    }

    /// cmux Remote's fresh host status (`refresh`: a new probe of its grants), or nil.
    public func computerUseStatus() async -> [String: Any]? {
        guard started, let answer = try? await call("refresh") else { return nil }
        let host = Self.object(answer)
        computerUse.take(host: host)
        if computerUse.workerState == "ready" { await refreshComputerUseApprovals() }
        return host
    }

    /// Restarts the Computer Use worker (a new process reads new grants; grants and sessions stay).
    public func restartComputerUse() async {
        _ = try? await call("restart", .object(["worker": .string("computer-use")]))
        _ = await computerUseStatus()
    }

    /// Reads the saved approvals into ``computerUse`` (nothing when the worker does not run).
    public func refreshComputerUseApprovals() async {
        guard started, let answer = try? await daemonRequest(ComputerUseApprovalsRequest(action: "list")) else { return }
        computerUse.take(approvals: Self.object(answer))
    }

    /// Forgets `appID`'s saved answer, or saves `decision` ("always" or "never") for it, then reads the list again.
    public func editComputerUseApproval(appID: String, decision: String?) async throws {
        _ = try await daemonRequest(ComputerUseApprovalsRequest(action: decision ?? "forget", appID: appID))
        await refreshComputerUseApprovals()
    }

    /// Ends every agent session of the Computer Use worker (`revoke_sessions`): their grants end.
    public func stopComputerUseSessions() async throws {
        _ = try await daemonRequest(ComputerUseApprovalsRequest(action: "revoke_sessions"))
    }

    /// Asks macOS for `permission` ("accessibility" or "screen-recording") in cmux Remote, so the
    /// prompt and System Settings name cmux Remote.
    public func requestGrant(_ permission: String) async {
        _ = try? await call("request", .object(["permission": .string(permission)]))
    }

    static func object(_ value: CmuxNextDaemon.JSONValue) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

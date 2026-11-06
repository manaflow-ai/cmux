// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
public import CmuxNextDaemon
import Foundation
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
    }
}

/// The policy the app sends cmux Remote's Computer Use worker: the person's `computerUse.*`
/// (`ComputerUseSettings.policyConfigJSON()`), the agent cursor's animation switches and this
/// Mac's name.
public struct CmuxRemoteComputerUsePolicy: Equatable, Sendable {
    public var policy: Data
    /// `ui.animations.enabled`, `ui.animations.cursor` and `ui.animationSpeed` not "off".
    public var cursorAnimates: Bool
    /// `ui.animationSpeed`'s pace (2: twice as fast).
    public var cursorSpeed: Double
    public var machine: String

    public init(policy: Data, cursorAnimates: Bool, cursorSpeed: Double, machine: String) {
        self.policy = policy
        self.cursorAnimates = cursorAnimates
        self.cursorSpeed = cursorSpeed
        self.machine = machine
    }

    /// `computer_use.config`'s params (the daemon forwards only the verified app's).
    var params: CmuxNextDaemon.JSONValue? {
        guard let object = try? JSONDecoder().decode(CmuxNextDaemon.JSONValue.self, from: policy), case .object = object else { return nil }
        return .object(["config": object, "machine": .string(machine),
                        "motion": .object(["enabled": .bool(cursorAnimates), "speed": .number(cursorSpeed)])])
    }
}

extension CmuxRemoteService {
    /// Sends the policy to cmux Remote (it starts, restarts or stops its Computer Use worker from it).
    public func applyComputerUse(_ policy: CmuxRemoteComputerUsePolicy) async {
        guard let params = policy.params else { return }
        do {
            let answer = try await call("computer_use.config", params)
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
        return host
    }

    /// Restarts the Computer Use worker (a new process reads new grants; grants and sessions stay).
    public func restartComputerUse() async {
        _ = try? await call("restart", .object(["worker": .string("computer-use")]))
        _ = await computerUseStatus()
    }

    /// Ends every agent session of the Computer Use worker (`revoke_sessions`): their grants end.
    public func stopComputerUseSessions() async throws {
        _ = try await call("computer_use.approvals", .object(["action": .string("revoke_sessions")]))
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

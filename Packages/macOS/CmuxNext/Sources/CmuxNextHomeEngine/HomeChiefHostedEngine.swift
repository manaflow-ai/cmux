public import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation

/// A hosted cloud Chief's brain: a cloud Chief no paired server runs (no `brain_place`), whose
/// brain runs in the Cloud service. Its settings go through the brain's own route as the signed-in
/// owner: `GET v1/chiefs/<agent>/brain` (`{config, turns_today}`) and `PUT v1/chiefs/<agent>/brain`
/// with `{model?, effort?}` (the new config). 2026-10-20: the card read a new Chief as a paired
/// server's and said "The server with this Chief is not connected." with empty pickers.
///
/// The brain runs one engine of its own, so there is no harness to pick (``choosesHarness``); it
/// offers the models and efforts the route takes. The route never clears a field, so "Default"
/// sets the brain's own default (``defaultModel``, ``defaultEffort``).
public nonisolated struct HomeChiefHostedEngine: HomeChiefEngineSource {
    /// One request to the Cloud service as the signed-in user: the status and the body. Throws
    /// ``Failure/signedOut`` with no signed-in account, any other error when it was not reached.
    public typealias Send = @MainActor @Sendable (_ method: String, _ path: String, _ body: Data?) async throws -> (status: Int, body: Data)

    public enum Failure: Error, Sendable {
        case signedOut
    }

    /// The Chief's agent id (`agent_…`); nil while the Chief list has not been read.
    let chief: @MainActor @Sendable () -> String?
    let send: Send
    /// The avatar stays this Mac's (`profile.json`, cosmetic).
    let files: HomeChiefFiles
    /// The lanes ``files`` is read on.
    let lanes: any MayBlockRunner
    public var isLocal: Bool { false }
    public var place: String? { nil }
    public var choosesHarness: Bool { false }

    /// The models the brain route takes for a Chief's turns (chief-brain/routes.ts).
    static let models: [ChiefEngineReport.Model] = [
        .init(id: "claude-opus-5-5", name: "Opus 5.5"),
        .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5"),
        .init(id: "claude-haiku-5-5", name: "Haiku 5.5"),
    ]
    /// The efforts the brain route takes (contract.ts `Effort`).
    static let efforts = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// The brain's own defaults (contract.ts `DEFAULT_MODEL`, `DEFAULT_EFFORT`).
    static let defaultModel = "claude-opus-5-5"
    static let defaultEffort = "low"

    public init(chief: @escaping @MainActor @Sendable () -> String?, send: @escaping Send, files: HomeChiefFiles,
                lanes: any MayBlockRunner) {
        self.chief = chief
        self.send = send
        self.files = files
        self.lanes = lanes
    }

    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        let config = try await call("GET", body: nil)
        let avatar = try await files.avatar(on: lanes)
        return Self.snapshot(config, avatar: avatar)
    }

    /// Sets model and effort (nil: the brain's default); a harness is not the brain's to change.
    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        let patch = Self.patch(fields)
        guard !patch.isEmpty else { return try await read() }
        let body = try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
        let config = try await call("PUT", body: body)
        let avatar = try await files.avatar(on: lanes)
        return Self.snapshot(config, avatar: avatar)
    }

    private func call(_ method: String, body: Data?) async throws(HomeChiefEngineError) -> [String: Any] {
        guard let agent = await chief() else { throw .cloudUnreachable }
        let reply: (status: Int, body: Data)
        do {
            reply = try await send(method, "v1/chiefs/\(agent)/brain", body)
        } catch let failure as Failure {
            switch failure {
            case .signedOut: throw .signedOut
            }
        } catch {
            throw .cloudUnreachable
        }
        return try Self.config(status: reply.status, body: reply.body)
    }

    /// The PUT body for a set: model and effort only, nil as the brain's default.
    static func patch(_ fields: [String: String?]) -> [String: String] {
        var patch: [String: String] = [:]
        if let model = fields["model"] { patch["model"] = model ?? defaultModel }
        if let effort = fields["effort"] { patch["effort"] = effort ?? defaultEffort }
        return patch
    }

    /// The brain's config from one reply (GET's `value.config`, PUT's `value`), or why not.
    static func config(status: Int, body: Data) throws(HomeChiefEngineError) -> [String: Any] {
        let json = (try? JSONSerialization.blockingJSONObject(with: body)) as? [String: Any] ?? [:]
        if status == 200, let value = json["value"] as? [String: Any] {
            return value["config"] as? [String: Any] ?? value
        }
        let error = json["error"] as? [String: Any]
        let code = error?["code"] as? String
        switch status {
        case 401: throw .signedOut
        // The deployment runs no Chief brains (`CHIEF_BRAIN_ENABLED` off).
        case 404: throw .cloudUnavailable
        case 200, 0, 500...: throw .cloudUnreachable
        default: throw .refused(reason: code ?? "http_\(status)", message: error?["message"] as? String ?? code ?? "HTTP \(status)")
        }
    }

    /// What the card shows for one config: its model and effort as chosen (the route always has
    /// both), the route's offer, and whether the brain is off (it then answers no message).
    static func snapshot(_ config: [String: Any], avatar: String?) -> HomeChiefSnapshot {
        let model = config["model"] as? String
        let effort = config["effort"] as? String
        var snapshot = HomeChiefSnapshot(harness: nil, model: model, effort: effort, avatar: avatar, turns: [])
        snapshot.models = models
        snapshot.efforts = efforts
        snapshot.effective = ChiefEngineReport.Engine(model: model, effort: effort)
        snapshot.brainOff = config["enabled"] as? Bool == false
        return snapshot
    }
}

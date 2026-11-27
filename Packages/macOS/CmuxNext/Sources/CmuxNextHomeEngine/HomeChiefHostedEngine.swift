public import CmuxNextDaemon
public import Foundation
import CmuxNextHomeModel

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
    public var isLocal: Bool { false }
    public var place: String? { nil }
    public var choosesHarness: Bool { false }

    // The route's models, efforts and defaults (chief-brain/routes.ts, contract.ts) are Rust's
    // `chief_settings.hostedOffer`; `hostedSnapshot` and `hostedPatch` apply them.

    public init(chief: @escaping @MainActor @Sendable () -> String?, send: @escaping Send, files: HomeChiefFiles) {
        self.chief = chief
        self.send = send
        self.files = files
    }

    public func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        let config = try await call("GET", body: nil)
        return Self.snapshot(config, avatar: files.avatar())
    }

    /// Sets model and effort (nil: the brain's default); a harness is not the brain's to change.
    public func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        let patch = Self.patch(fields)
        guard !patch.isEmpty else { return try await read() }
        let body = try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
        return Self.snapshot(try await call("PUT", body: body), avatar: files.avatar())
    }

    private func call(_ method: String, body: Data?) async throws(HomeChiefEngineError) -> [String: JSONValue] {
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
    /// Rust's `chief_settings.hostedPatch`.
    static func patch(_ fields: [String: String?]) -> [String: String] {
        (try? HomeRules.call("chief_settings.hostedPatch", PatchRequest(fields: fields))) ?? [:]
    }

    /// The brain's config from one reply (GET's `value.config`, PUT's `value`), or why not.
    /// Rust's `chief_settings.hostedConfig`.
    static func config(status: Int, body: Data) throws(HomeChiefEngineError) -> [String: JSONValue] {
        let reply: ConfigReply
        do {
            reply = try HomeRules.call("chief_settings.hostedConfig",
                                       ConfigRequest(status: status, bodyText: String(decoding: body, as: UTF8.self)))
        } catch {
            throw .cloudUnreachable
        }
        if let config = reply.config { return config }
        throw HomeChiefEngineError(wire: reply.error ?? .init(kind: "cloudUnreachable"))
    }

    /// What the card shows for one config: its model and effort as chosen (the route always has
    /// both), the route's offer, and whether the brain is off (it then answers no message).
    /// Rust's `chief_settings.hostedSnapshot`.
    static func snapshot(_ config: [String: JSONValue], avatar: String?) -> HomeChiefSnapshot {
        let wire: HomeChiefSnapshotWire? = try? HomeRules.call("chief_settings.hostedSnapshot", SnapshotRequest(config: config, avatar: avatar))
        return wire?.snapshot(turns: []) ?? HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: avatar, turns: [])
    }

    private nonisolated struct PatchRequest: Encodable {
        var fields: [String: String?]
    }

    private nonisolated struct ConfigRequest: Encodable {
        var status: Int
        var bodyText: String
    }

    private nonisolated struct ConfigReply: Decodable {
        var config: [String: JSONValue]?
        var error: HomeChiefEngineError.Wire?
    }

    private nonisolated struct SnapshotRequest: Encodable {
        var config: [String: JSONValue]
        var avatar: String?
    }
}

public import CmuxNextSettings
import CryptoKit
public import Foundation
import Observation

/// The active team's shared agent keys (Cloud multiplayer, contract C4): one Claude and one Codex key
/// that the team's Cloud machines use in place of each member's own. Owners and admins set, replace
/// and remove them; members only see whether one is set. Calls the owner API as the person
/// (`team.agent_key.status`, `.set`, `.remove`), like ``GitHubConnections``.
///
/// A pasted key is only a parameter of ``save(agent:kind:secret:)``: it is sent once and never kept,
/// logged or put in page state. A save whose answer was lost keeps its idempotency key for a safe
/// retry, bound to a keyed digest of that exact paste (a per-launch random key, so the digest is
/// useless outside this object), because the API answers a replayed key with the first key's row.
@MainActor @Observable
public final class TeamAgentKeys {
    public typealias Scope = GitHubConnections.Scope
    public typealias Call = GitHubConnections.Call
    /// `refused` carries the API's error code (`auth.forbidden`, `validation.invalid`, …).
    public enum Failure: Error, Equatable { case changedAccount, invalidReply, refused(String) }

    public static let agents = ["claude", "codex"]
    public static let kinds = ["api_key", "oauth"]
    static let secretLength = 8...16_384

    struct Slot: Hashable { let scope: Scope; let agent: String }
    struct Problem: Equatable { let scope: Scope; let agent: String?; let code: String }

    @ObservationIgnored private let scope: () -> Scope?
    @ObservationIgnored private let call: Call
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let digestKey = SymmetricKey(size: .bits256)
    @ObservationIgnored private var saveKeys: [Slot: (digest: Data, key: String)] = [:]
    @ObservationIgnored private var removeKeys: [Slot: String] = [:]
    private var loadedScope: Scope?
    private var workingScope: Scope?
    private var generation = 0
    private(set) var rows: [JSONValue] = []
    private(set) var manage = false
    private(set) var problem: Problem?
    private(set) var done: (scope: Scope, agent: String, removed: Bool)?

    public init(scope: @escaping () -> Scope?, call: @escaping Call, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        self.call = call
        self.now = now
    }

    public var scopeIsSignedOut: Bool { scope() == nil }
    /// The personal team has no one to share a key with.
    public var isPersonal: Bool { scope().map { $0.team == nil } ?? false }
    public var busy: Bool { workingScope != nil && workingScope == scope() }
    public var loaded: Bool { scope() != nil && loadedScope == scope() }
    public var canManage: Bool { loaded && manage }
    public var currentAgents: [JSONValue] { loaded ? rows : [] }
    var currentProblem: Problem? { problem.flatMap { $0.scope == scope() ? $0 : nil } }
    var currentDone: (agent: String, removed: Bool)? { done.flatMap { $0.scope == scope() ? (agent: $0.agent, removed: $0.removed) : nil } }

    /// `team.agent_key.status` for the active team; on Settings mount, focus, refresh and a team switch.
    public func refresh() async { await run(nil) { _, _ in } }

    /// Sets or replaces AGENT's team key. SECRET is trimmed (a paste usually ends in a newline) and
    /// checked like the API does, so a bad paste never leaves the Mac.
    public func save(agent: String, kind: String, secret: String) async {
        guard let bound = scope(), bound.team != nil, canManage, !busy, Self.agents.contains(agent) else { return }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.kinds.contains(kind), Self.secretLength.contains(trimmed.count), Self.shapeIsValid(kind: kind, secret: trimmed) else {
            problem = Problem(scope: bound, agent: agent, code: "validation.invalid")
            done = nil
            return
        }
        let slot = Slot(scope: bound, agent: agent)
        let digest = Data(HMAC<SHA256>.authenticationCode(for: Data("\(kind)\u{0}\(trimmed)".utf8), using: digestKey))
        if saveKeys[slot]?.digest != digest { saveKeys[slot] = (digest, UUID().uuidString) }
        let key = saveKeys[slot]?.key ?? UUID().uuidString
        await run(agent) { bound, ticket in
            do {
                _ = try await self.call(bound, "team.agent_key.set", ["agent": .string(agent), "kind": .string(kind), "secret": .string(trimmed)], key)
                if self.generation == ticket { self.saveKeys[slot] = nil }
                self.done = (bound, agent, false)
            } catch {
                if self.generation == ticket, !Self.mayHaveWritten(error) { self.saveKeys[slot] = nil }
                throw error
            }
        }
    }

    /// Removes AGENT's team key; members' machines go back to their own keys.
    public func remove(agent: String) async {
        guard let bound = scope(), bound.team != nil, canManage, !busy, Self.agents.contains(agent),
              currentAgents.contains(where: { $0["agent"]?.stringValue == agent && $0["set"]?.boolValue == true }) else { return }
        let slot = Slot(scope: bound, agent: agent)
        if removeKeys[slot] == nil { removeKeys[slot] = UUID().uuidString }
        let key = removeKeys[slot] ?? UUID().uuidString
        await run(agent) { bound, ticket in
            do {
                _ = try await self.call(bound, "team.agent_key.remove", ["agent": .string(agent)], key)
                if self.generation == ticket { self.removeKeys[slot] = nil }
                self.done = (bound, agent, true)
            } catch {
                if self.generation == ticket, !Self.mayHaveWritten(error) { self.removeKeys[slot] = nil }
                throw error
            }
        }
    }

    /// One gesture for the active scope: MUTATE (nothing for a refresh), then the same status read.
    /// A reply that lands after the account or team changed, or after a newer gesture began, is dropped.
    private func run(_ agent: String?, _ mutate: (Scope, Int) async throws -> Void) async {
        guard let bound = scope(), bound.team != nil, workingScope != bound else { return }
        generation += 1
        let ticket = generation
        workingScope = bound
        problem = nil
        if agent != nil { done = nil }
        defer { if generation == ticket { workingScope = nil } }
        do {
            try await mutate(bound, ticket)
            let value = try await call(bound, "team.agent_key.status", [:], nil)
            guard scope() == bound, generation == ticket else { return }
            guard let agents = value["agents"]?.arrayValue else { throw Failure.invalidReply }
            rows = Self.agents.map { name in agents.first { $0["agent"]?.stringValue == name } ?? ["agent": .string(name), "set": false] }
            manage = value["can_manage"]?.boolValue == true
            loadedScope = bound
        } catch {
            guard scope() == bound, generation == ticket else { return }
            if agent != nil { done = nil }
            problem = Problem(scope: bound, agent: agent, code: Self.code(error))
        }
    }

    /// A lost answer, an unreachable owner or an answer that arrived after an account switch may
    /// hide a write: its key is kept for the retry. Only a definitive refusal drops it.
    private nonisolated static func mayHaveWritten(_ error: any Error) -> Bool {
        guard let failure = error as? Failure else { return true }
        switch failure {
        case .refused(let code): return code == "owner.unreachable"
        case .changedAccount: return true
        case .invalidReply: return false
        }
    }

    private nonisolated static func code(_ error: any Error) -> String {
        guard let failure = error as? Failure else { return "owner.unreachable" }
        switch failure {
        case .refused(let code): return code
        case .invalidReply, .changedAccount: return "invalid_reply"
        }
    }

    /// The API's shape check (backend team-agent-keys.ts `agentKeyProblem`): printable ASCII with no
    /// spaces, or for a subscription also a sign-in file (a JSON object).
    nonisolated static func shapeIsValid(kind: String, secret: String) -> Bool {
        let printable = secret.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
        if kind == "api_key" { return printable }
        if secret.hasPrefix("{") {
            guard !secret.unicodeScalars.contains(where: { ($0.value < 0x20 && ![0x09, 0x0A, 0x0D].contains($0.value)) || $0.value == 0x7F }),
                  case .object(_)? = try? JSONValue.parse(Data(secret.utf8)) else { return false }
            return true
        }
        return printable
    }
}

extension TeamAgentKeys: CustomStringConvertible {
    /// Never a key: the scope and which agents are set.
    public nonisolated var description: String { "TeamAgentKeys" }
}

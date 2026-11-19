public import CmuxNextCloud
public import CmuxNextSettings
public import Foundation
import Observation

/// The active team's members policy for model connections (Settings > Models,
/// cmux-tui/docs/model-connections.md): whether members' own connections serve their Cloud threads
/// (`ownConnections`, default on) and whether members choose what a thread does when its connection
/// runs out (`chooseRunout`, default off). Every member reads it (`team.models_policy.get`); owners
/// and admins change it (`team.models_policy.set`) through the owner API as the person, like
/// ``TeamAgentKeys``. The personal team has none.
@MainActor @Observable
public final class TeamModelsPolicy {
    public typealias Scope = TeamAgentKeys.Scope
    public typealias Call = TeamAgentKeys.Call

    public struct Policy: Equatable, Sendable {
        public var ownConnections: Bool
        public var chooseRunout: Bool
        public var canEdit: Bool
    }

    @ObservationIgnored private let scope: () -> Scope?
    @ObservationIgnored private let call: Call
    private var loaded: (scope: Scope, policy: Policy)?
    private var generation = 0
    /// The last refusal's API code (`auth.forbidden`, `owner.unreachable`, ...), for the active scope.
    private(set) var problem: (scope: Scope, code: String)?

    public init(scope: @escaping () -> Scope?, call: @escaping Call) {
        self.scope = scope
        self.call = call
    }

    /// The policy of the active team, nil before a read answered, for the personal team or signed out.
    public var current: Policy? {
        guard let bound = scope(), bound.team != nil, let loaded, loaded.scope == bound else { return nil }
        return loaded.policy
    }

    var currentProblem: String? { problem.flatMap { $0.scope == scope() ? $0.code : nil } }

    /// `team.models_policy.get` for the active team.
    public func refresh() async {
        guard let bound = scope(), bound.team != nil else { return }
        generation += 1
        let ticket = generation
        do {
            let value = try await call(bound, "team.models_policy.get", [:], nil)
            guard scope() == bound, generation == ticket else { return }
            loaded = (bound, try Self.policy(value))
            problem = nil
        } catch {
            guard scope() == bound, generation == ticket else { return }
            problem = (bound, Self.code(error))
        }
    }

    /// `team.models_policy.set` with the fields given (nil keeps a field); owners and admins only.
    /// Throws the API's refusal so the page can say why.
    public func set(ownConnections: Bool?, chooseRunout: Bool?) async throws {
        guard let bound = scope(), bound.team != nil else { throw TeamAgentKeys.Failure.refused("auth.forbidden") }
        var params: [String: JSONValue] = [:]
        if let ownConnections { params["own_connections"] = .bool(ownConnections) }
        if let chooseRunout { params["choose_runout"] = .bool(chooseRunout) }
        guard !params.isEmpty else { return }
        do {
            let value = try await call(bound, "team.models_policy.set", .object(params), UUID().uuidString)
            guard scope() == bound else { return }
            // The change's answer is the newest row: a read that started before it answers no more.
            generation += 1
            loaded = (bound, try Self.policy(value))
            problem = nil
        } catch {
            if scope() == bound { problem = (bound, Self.code(error)) }
            throw error
        }
    }

    /// The API's `TeamModelsPolicyState` (snake_case) as the page's policy.
    nonisolated static func policy(_ value: JSONValue) throws -> Policy {
        guard let own = value["own_connections"]?.boolValue, let runout = value["choose_runout"]?.boolValue else {
            throw TeamAgentKeys.Failure.invalidReply
        }
        return Policy(ownConnections: own, chooseRunout: runout, canEdit: value["can_edit"]?.boolValue == true)
    }

    private nonisolated static func code(_ error: any Error) -> String {
        if case .refused(let code)? = error as? TeamAgentKeys.Failure { return code }
        return error is TeamAgentKeys.Failure ? "invalid_reply" : "owner.unreachable"
    }

    /// The live policy of the Cloud sign-in AUTH's active team, through the owner API at OWNER_API.
    public static func live(auth: CloudAuth, ownerAPI: URL, preview: Bool) -> TeamModelsPolicy {
        let owner = TeamAgentKeys.ownerAPICall(auth: auth, ownerAPI: ownerAPI, preview: preview)
        return TeamModelsPolicy(scope: owner.scope, call: owner.call)
    }
}

import CmuxMobileModel
import Foundation

/// The signed-in account's own Cloud calls beyond the Chief conversation: Automations
/// (`automation.*` over `/v1/read` and `/v1/ops`) and Connect GitHub (`integration.*`). Every call
/// carries this phone's own access token, as the Chief's do; nothing goes through a Mac or the relay.
public struct AccountCloud: Sendable {
    /// Why a call did not answer, in the service's words where it gave them.
    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        case refused(status: Int, code: String, message: String)
        case unreachable
        case badReply

        public var description: String {
            switch self {
            case let .refused(_, code, message): message.isEmpty ? code : message
            case .unreachable: String(localized: "Couldn't reach cmux Cloud. Check your connection.")
            case .badReply: String(localized: "cmux Cloud answered something the phone can't read.")
            }
        }

        public var code: String? {
            if case let .refused(_, code, _) = self { return code }
            return nil
        }
    }

    /// The call never reached cmux Cloud (no answer, no network): a state that ends on its own, so a
    /// page that keeps its cached rows says nothing about it until it has lasted
    /// ``QuietStatusGate/threshold`` (hq docs/handbook/connection-state-with-no-action-or-bound.md).
    public static func isUnreachable(_ error: any Error) -> Bool {
        guard let failure = error as? Failure else { return true }
        return failure == .unreachable
    }

    let http: ChiefCloudHTTP

    /// `/v1/read {op, params}`: the reply's `value` as JSON bytes. `team` is the Cloud team id the
    /// read acts in (``ChiefSources/cloudTeamID(stackTeamID:)``); nil reads the personal team.
    public func read(_ op: String, params: [String: any Sendable] = [:], team: String? = nil) async throws -> Data {
        try await call("/v1/read", ["op": op, "params": params], team: team)
    }

    /// `/v1/ops {op, params, idempotency_key, origin: user}`: a write the person made; a retry
    /// with the same key applies once.
    public func mutate(_ op: String, params: [String: any Sendable], key: String, team: String? = nil) async throws -> Data {
        try await call("/v1/ops", ["op": op, "params": params, "idempotency_key": key, "origin": "user"], team: team)
    }

    private func call(_ path: String, _ object: [String: any Sendable], team: String?) async throws -> Data {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: object) } catch { throw Failure.badReply }
        let reply: ChiefCloudHTTP.Reply
        do { reply = try await http.send("POST", path, body: body, team: team) } catch {
            throw Self.cancellation(error) ?? Failure.unreachable
        }
        let value: Any?
        do { value = try ChiefCloudHTTP.value(reply) } catch let ChiefCloudError.refused(status, code, message) {
            throw Failure.refused(status: status, code: code, message: message)
        } catch {
            throw Failure.badReply
        }
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// Only a successful list envelope, including an explicit empty array, can replace cached rows.
    static func listItems(_ key: String, in value: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: value) as? [String: Any],
              let items = root[key] as? [[String: Any]] else { throw Failure.badReply }
        return items
    }

    /// A cancelled call as `CancellationError` (URLSession reports `URLError.cancelled`), so a page
    /// that left or reloaded never shows it as a failure.
    static func cancellation(_ error: any Error) -> CancellationError? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return CancellationError() }
        return nil
    }

}

extension ChiefSources {
    /// Both lists read the authenticated personal team (no team header).
    /// Backend, build space and Stack project each identify a separate source of rows.
    public var personalListIdentity: [String]? {
        guard let userID, let http, http.buildSpace.refusal == nil else { return nil }
        return [userID, http.base.absoluteString, http.buildSpace.space?.headerValue ?? "", stackProjectID ?? ""]
    }

    func personalListSource(_ screen: String) -> (cache: LastKnownList?, account: @MainActor () -> AccountCloud?) {
        let identity = personalListIdentity
        let cache = identity.flatMap { parts in
            userID.map { LastKnownListStore.standard.list(accountID: $0, screen: screen, context: Array(parts.dropFirst())) }
        }
        return (cache, { [weak self] in
            guard let self, self.personalListIdentity == identity else { return nil }
            return self.account
        })
    }

    /// This account's own Cloud calls, while signed in to a build with a Cloud service.
    public var account: AccountCloud? {
        guard let http else { return nil }
        return AccountCloud(http: http)
    }
}

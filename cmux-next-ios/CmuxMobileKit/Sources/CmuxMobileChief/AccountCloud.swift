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

    let http: ChiefCloudHTTP

    /// `/v1/read {op, params}`: the reply's `value` as JSON bytes.
    public func read(_ op: String, params: [String: any Sendable] = [:]) async throws -> Data {
        try await call("/v1/read", ["op": op, "params": params])
    }

    /// `/v1/ops {op, params, idempotency_key, origin: user}`: a write the person made; a retry
    /// with the same key applies once.
    public func mutate(_ op: String, params: [String: any Sendable], key: String) async throws -> Data {
        try await call("/v1/ops", ["op": op, "params": params, "idempotency_key": key, "origin": "user"])
    }

    private func call(_ path: String, _ object: [String: any Sendable]) async throws -> Data {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: object) } catch { throw Failure.badReply }
        let reply: ChiefCloudHTTP.Reply
        do { reply = try await http.send("POST", path, body: body) } catch {
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

    /// A cancelled call as `CancellationError` (URLSession reports `URLError.cancelled`), so a page
    /// that left or reloaded never shows it as a failure.
    static func cancellation(_ error: any Error) -> CancellationError? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return CancellationError() }
        return nil
    }

}

extension ChiefSources {
    /// This account's own Cloud calls, while signed in to a build with a Cloud service.
    public var account: AccountCloud? {
        guard let http else { return nil }
        return AccountCloud(http: http)
    }
}

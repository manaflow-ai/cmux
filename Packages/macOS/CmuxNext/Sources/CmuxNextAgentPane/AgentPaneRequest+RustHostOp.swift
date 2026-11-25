public import CmuxNextDaemon
import CmuxNextWindowRules
import Foundation
import os

/// The page messages Rust decodes (cmux-tui cmux-window-rules `chat::host_op`, its tests the checks' tests): the
/// Cloud environment editor, the Cloud reservation, the Cloud repository actions and the GitHub section. The host
/// hands Rust the page's message over the app FFI's JSON channel (`window_chat_agent_host_op`) and builds the
/// request from the checked answer; it checks nothing itself. Every other method is still decoded in
/// ``AgentPaneRequest/init(body:)`` until it moves (cmuxterm-hq docs/rfd/drafts/why-swift.md).
extension AgentPaneRequest {
    /// The methods Rust decodes, read once per launch (`window_chat_agent_host_op_methods`).
    nonisolated static let rustHostOpMethods: Set<String> = {
        struct Empty: Encodable {}
        struct Methods: Decodable { var methods: [String] }
        return Set(WindowRules().call("window_chat_agent_host_op_methods", Empty(), as: Methods.self)?.methods ?? [])
    }()

    /// Rust's answer for one page message (`HostOp`): `case` names it, the rest are its fields.
    private nonisolated struct RustHostOp: Decodable {
        struct GitHub: Decodable {
            var request: String
            var repo: String?
            var query: String?
            var candidates: [String]?
            var key: String?
            var url: String?
        }

        var `case`: String
        var method: String?
        var action: String?
        var params: JSONValue?
        var release: Bool?
        var composeKey: String?
        var replacesChat: String?
        var atOpen: Bool?
        var auto: Bool?
        var github: GitHub?
    }

    /// The request for a page message Rust decodes; `.unsupported(method)` for one it refuses or when the FFI does
    /// not answer.
    nonisolated static func rustHostOp(method: String, params: [String: Any]?) -> AgentPaneRequest {
        let body: [String: Any] = ["method": method, "params": params ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body),
              let answer = WindowRules().callData("window_chat_agent_host_op", data),
              let decoded = try? JSONDecoder().decode(RustHostOp.self, from: answer) else {
            rustHostOpLog.fault("host op \(method, privacy: .public): Rust did not answer")
            return .unsupported(method)
        }
        return request(decoded, method: method) ?? .unsupported(method)
    }

    private nonisolated static func request(_ op: RustHostOp, method: String) -> AgentPaneRequest? {
        switch op.case {
        case "cloudEnvironment":
            guard let action = op.action, let params = op.params else { return nil }
            return .cloudEnvironment(AgentPaneCloudEnvironmentRequest(action: action, params: params))
        case "cloudReservation":
            guard let release = op.release, let params = op.params else { return nil }
            return .cloudReservation(AgentPaneCloudReservationRequest(release: release, params: params, composeKey: op.composeKey,
                                                                      replacesChat: op.replacesChat, atOpen: op.atOpen ?? false,
                                                                      auto: op.auto ?? false))
        case "cloudRepository":
            guard let method = op.method, let params = op.params else { return nil }
            return .cloudRepository(AgentPaneCloudRepositoryRequest(method: method, params: params))
        case "gitHub":
            return op.github.flatMap(gitHub).map(AgentPaneRequest.gitHub)
        default:
            return nil
        }
    }

    private nonisolated static func gitHub(_ request: RustHostOp.GitHub) -> AgentPaneGitHubRequest? {
        switch request.request {
        case "status": return .status
        case "connect": return .connect(repo: request.repo)
        case "repos": return .repos(query: request.query)
        case "checkout":
            guard let repo = request.repo, let key = request.key else { return nil }
            return .checkout(repo: repo, candidates: request.candidates ?? [], key: key)
        case "cloneUrl":
            guard let url = request.url, let key = request.key else { return nil }
            return .cloneURL(url: url, key: key)
        default: return nil
        }
    }

    private nonisolated static let rustHostOpLog = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane")
}

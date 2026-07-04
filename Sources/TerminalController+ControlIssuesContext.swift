import CmuxControlSocket
import Foundation

extension TerminalController: ControlIssuesContext {
    func controlIssuesList() -> ControlCallResult {
        issueInboxControlResult(.ok(issueInboxListPayload()))
    }

    func controlIssuesOpen(params: [String: JSONValue]) -> ControlCallResult {
        issueInboxControlResult(issueInboxOpen(params: issueInboxFoundationParams(params)))
    }

    func controlIssuesSpawnWorkspace(
        issueID: String,
        cwd: String?,
        params: [String: JSONValue]
    ) -> ControlCallResult {
        issueInboxControlResult(
            issueInboxSpawnWorkspace(
                issueID: issueID,
                cwd: cwd,
                params: issueInboxFoundationParams(params)
            )
        )
    }

    private func issueInboxControlResult(_ result: V2CallResult) -> ControlCallResult {
        switch result {
        case .ok(let payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case .err(let code, let message, let data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap { JSONValue(foundationObject: $0) }
            )
        }
    }

    private func issueInboxFoundationParams(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues(\.foundationObject)
    }
}

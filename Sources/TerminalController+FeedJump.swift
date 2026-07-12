import Foundation

extension TerminalController {
    nonisolated func v2FeedJump(params: [String: Any]) -> V2CallResult {
        guard let workstreamID = params["workstream_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.jump requires workstream_id",
                data: nil
            )
        }
        let matched: Bool
        if let parsed = FeedJumpResolver.parse(workstreamID) {
            matched = FeedJumpResolver.lookup(
                agent: parsed.agent,
                sessionId: parsed.sessionId
            ) != nil
        } else {
            matched = false
        }
        return .ok([
            "workstream_id": workstreamID,
            "matched": matched,
        ])
    }
}

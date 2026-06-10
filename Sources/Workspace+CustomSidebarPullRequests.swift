import CmuxSwiftRender
import Foundation

extension Workspace {
    /// Pull-request values projected for the custom-sidebar interpreter
    /// context (`workspaces[i].pr` / `workspaces[i].prs`).
    func customSidebarPullRequestValues() -> [SwiftValue] {
        guard let pullRequest else { return [] }
        return [Self.customSidebarPullRequestValue(pullRequest)]
    }

    private static func customSidebarPullRequestValue(_ pullRequest: SidebarPullRequestState) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "number": .int(pullRequest.number),
            "label": .string(pullRequest.label),
            "url": .string(pullRequest.url.absoluteString),
            "status": .string(pullRequest.status.rawValue),
            "stale": .bool(pullRequest.isStale),
        ]
        if let branch = pullRequest.branch { fields["branch"] = .string(branch) }
        return .object(fields)
    }
}

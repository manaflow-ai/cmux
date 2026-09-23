internal import Foundation

/// Explicit workspace handoffs parse on the worker and enqueue their state
/// transition on the main-actor mutation bus. The socket worker never blocks
/// on UI state; the response acknowledges that the mutation was accepted.
extension ControlCommandCoordinator {
    nonisolated func sidebarReportWorkspacePullRequest(
        _ args: String,
        context: (any ControlCommandContext)?
    ) -> String {
        let parsed = sidebarParseOptions(args)
        guard parsed.positional.count == 2,
              Set(parsed.options.keys).isSubset(of: ["tab", "state", "branch", "label"]),
              let tabArg = parsed.options["tab"], UUID(uuidString: tabArg) != nil,
              let number = Int(parsed.positional[0]), number > 0,
              let url = URL(string: parsed.positional[1]),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 5, url.pathComponents[3] == "pull",
              Int(url.pathComponents[4]) == number,
              !url.pathComponents[1].isEmpty, !url.pathComponents[2].isEmpty,
              let context else {
            return context?.controlSidebarManualPullRequestError(invalidTarget: false) ?? "ERROR"
        }
        let status = (parsed.options["state"] ?? "open").lowercased()
        let label = (parsed.options["label"] ?? "PR").trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.controlSidebarIsValidPullRequestState(status), !label.isEmpty else {
            return context.controlSidebarManualPullRequestError(invalidTarget: false)
        }
        context.controlSidebarScheduleManualPullRequest(
            tabArg: tabArg,
            number: number,
            label: String(label.prefix(16)),
            url: url,
            statusRawValue: status,
            branch: sidebarNormalizedOptionValue(parsed.options["branch"])
        )
        return "OK"
    }

    nonisolated func sidebarClearWorkspacePullRequest(
        _ args: String,
        context: (any ControlCommandContext)?
    ) -> String {
        let parsed = sidebarParseOptions(args)
        guard parsed.positional.isEmpty, Set(parsed.options.keys) == ["tab"],
              let tabArg = parsed.options["tab"], UUID(uuidString: tabArg) != nil,
              let context else {
            return context?.controlSidebarManualPullRequestError(invalidTarget: false) ?? "ERROR"
        }
        context.controlSidebarScheduleManualPullRequestClear(tabArg: tabArg)
        return "OK"
    }
}

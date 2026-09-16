internal import Foundation

/// Explicit workspace handoffs share one synchronous mutation seam. Parsing
/// stays on the worker; the small main-actor hop acknowledges the applied
/// state before replying, unlike passive panel telemetry's enqueue-only ACK.
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
        let attached = context.controlSidebarOnMain {
            $0.controlSidebarAttachManualPullRequest(
                tabArg: tabArg, number: number, label: String(label.prefix(16)), url: url,
                statusRawValue: status, branch: sidebarNormalizedOptionValue(parsed.options["branch"])
            )
        }
        return attached ? "OK" : context.controlSidebarManualPullRequestError(invalidTarget: true)
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
        let cleared = context.controlSidebarOnMain { $0.controlSidebarClearManualPullRequest(tabArg: tabArg) }
        return cleared ? "OK" : context.controlSidebarManualPullRequestError(invalidTarget: true)
    }
}

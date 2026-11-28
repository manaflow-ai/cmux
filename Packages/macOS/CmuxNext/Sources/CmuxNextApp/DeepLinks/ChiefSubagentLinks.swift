import CmuxNextActions
import Foundation

/// A click on a Chief subagent's link in Home (`[a1](cmux://chief/<home id>/session/<id>)`,
/// optchat-chief `workspaces::subagent_link`). The Chief writes the `cmux` scheme whatever the
/// build, so the link is opened as this build's `link.open` (the one shared path), and only for
/// this app's own Chief home: Home's allowlist is this action and this Chief's subagents.
enum ChiefSubagentLinks {
    /// The scheme the Chief writes.
    static let chiefScheme = "cmux"

    /// Runs `link.open` on `url` when it is this Chief's subagent link; false (nothing runs) for
    /// any other URL or another Chief home.
    @MainActor
    @discardableResult
    static func open(_ url: URL, services: AppServices) -> Bool {
        let link = DeepLink.parse(url, scheme: chiefScheme) ?? DeepLink.parse(url, scheme: services.linkScheme)
        guard let link, case .chiefSession(let home, _) = link.target, link.machine == nil,
              services.agentTabs.chiefHost == "chief:" + home,
              let text = link.url(scheme: services.linkScheme)?.absoluteString else { return false }
        return services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(text)], origin: .user))
    }
}

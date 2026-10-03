import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// cmux:// links: `link.open`, the one resolution path every link takes,
/// and Copy Link on a workspace, pane or tab, which writes the running
/// build's scheme and the object's durable resource id.
enum LinkHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("link.open", run: { invocation in
            let text = invocation["url"]?.stringValue ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let link = DeepLink.parse(url, scheme: services.linkScheme) else {
                throw ActionFailure(message: RefusalStrings.linkNotRecognized(text))
            }
            // Read before anything moves: a run this client's user did not
            // start (a script, an agent) still navigates, as it asked, but
            // never takes the key window.
            let background = invocation["background"]?.boolValue == true || !services.viewChangeAllowed
            try DeepLinkNavigator(services: services).open(link, background: background)
        })
        registry.bind("palette.copyWorkspaceLink", run: { invocation in
            context.copy(try services.link(workspace: try context.workspace(invocation).model))
        })
        registry.bind("palette.copyPaneLink", run: { invocation in
            guard let pane = context.daemonPane(invocation) else { return }
            context.copy(try services.link(pane: pane))
        })
        registry.bind("palette.copySurfaceLink", run: { invocation in
            // An agent tab's link is its chat's: `cmux://session/<id>`.
            if let key = agentTab(invocation, services: services) {
                context.copy(try services.link(agentTab: key))
                return
            }
            guard let (tab, _) = context.daemonTab(invocation) else { return }
            context.copy(try services.link(tab: tab))
        })
    }

    /// The agent tab an invocation names: an explicit `local-agent:` tab
    /// target, else the focused pane's selected tab when it is one. Nil
    /// for anything else, which the daemon tab path resolves or refuses.
    static func agentTab(_ invocation: ActionInvocation, services: AppServices) -> String? {
        let explicit = [invocation.target, invocation["tab"]?.targetValue, invocation["pane"]?.targetValue]
            .compactMap { $0 }.first { $0.kind == .tab || $0.kind == .pane }
        if let explicit {
            return explicit.kind == .tab && explicit.id.hasPrefix(LocalAgentTab.prefix) ? explicit.id : nil
        }
        guard let selected = services.windows.active?.focusedPane?.stripModel.selectedID?.rawValue,
              selected.hasPrefix(LocalAgentTab.prefix) else { return nil }
        return selected
    }
}

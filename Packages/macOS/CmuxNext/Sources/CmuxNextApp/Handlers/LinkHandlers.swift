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
            guard let (tab, _) = context.daemonTab(invocation) else { return }
            context.copy(try services.link(tab: tab))
        })
    }
}

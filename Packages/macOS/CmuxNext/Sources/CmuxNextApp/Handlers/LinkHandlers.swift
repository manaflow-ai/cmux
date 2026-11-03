import AppKit
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
            // Read before anything moves: a run this client's user did not
            // start (a script, an agent) still navigates, as it asked, but
            // never takes the key window.
            let background = invocation["background"]?.boolValue == true || !ActionRunScope.viewChangeAllowed()
            // `<scheme>://stashed` (opened from another app, Open Link…) is the Stashed Tabs page.
            if let url = URL(string: trimmed), url.scheme?.caseInsensitiveCompare(services.linkScheme) == .orderedSame,
               url.host()?.lowercased() == "stashed" {
                _ = try StashHandlers.show(services, focus: !background)
                return
            }
            guard let url = URL(string: trimmed), let parsed = DeepLink.read(url, scheme: services.linkScheme) else {
                throw ActionFailure(message: RefusalStrings.linkNotRecognized(text))
            }
            try DeepLinkNavigator(services: services).open(parsed.link, background: background)
            // A parameter cmux does not use never costs an agent link its chat: it opens, and a
            // toast names what was left out, so a stray `?cwd=…` is visible instead of silent.
            // Only this kind, and only after it opened: the older kinds have always ignored
            // their extra parameters (a shared `?utm_source=…`, nightly's `stable_*_id`), and a
            // link that refused shows why it refused instead.
            // It is a notice in the window the reader is in, so a run this user did not start
            // (`background`) and one whose caller collects what the run said instead of showing
            // it (`isCapturingRefusal`: the socket, the CLI) show no HUD. Not
            // `refusalHasCaller`, which also covers a reporting run such as the palette's: that
            // one only shows a reason `refuse()` reported, which this notice is not, so gating on
            // it would leave Open Link… from the palette with no word of a stray parameter.
            if case .agent = parsed.link.target, !background, !registry.isCapturingRefusal,
               let notice = RefusalStrings.linkParametersIgnored(parsed.ignoredParameters,
                                                                 used: parsed.link.usedParameters) {
                services.refusalHUD.show(notice, in: services.windows.active?.window ?? services.keyWindowSource())
            }
        })
        // Every selected row, one link per line, as classic's Copy Workspace Links (#27709).
        registry.bindEffect("palette.copyWorkspaceLink", requires: nil, effect: { invocation in
            context.copy(try WindowMembershipHandlers.rowTargets(invocation, context).map { try services.link(workspace: $0) }.joined(separator: "\n"))
            return .done
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

    /// The agent tab an invocation names: an explicit agent chat tab
    /// target, else the focused pane's selected tab when it is one. Nil
    /// for anything else, which the daemon tab path resolves or refuses.
    static func agentTab(_ invocation: ActionInvocation, services: AppServices) -> String? {
        let explicit = [invocation.target, invocation["tab"]?.targetValue, invocation["pane"]?.targetValue]
            .compactMap { $0 }.first { $0.kind == .tab || $0.kind == .pane }
        if let explicit {
            return explicit.kind == .tab && services.agentTabs.isAgentTab(explicit.id) ? explicit.id : nil
        }
        guard let selected = services.windows.active?.focusedPane?.stripModel.selectedID?.rawValue,
              services.agentTabs.isAgentTab(selected) else { return nil }
        return selected
    }
}

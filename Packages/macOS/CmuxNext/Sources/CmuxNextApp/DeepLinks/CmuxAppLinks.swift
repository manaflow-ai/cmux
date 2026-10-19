import CmuxNextActions
import Foundation

/// A click on a cmux app link in rendered Markdown (the Home transcript, an agent chat, a
/// Markdown file page) or a terminal: `cmux://workspace/<ws_…>`, `pane/<pane_…>`, `tab/<tab_…>`,
/// `session/<id>`, or a Chief subagent's `chief/<home id>/session/<id>` (optchat-chief
/// `workspaces::subagent_link`). The Chief and its documents write the `cmux` scheme whatever the
/// build, so the link is opened as this build's `link.open` (the one shared path) and never goes
/// to another app through the system: the plain `cmux` scheme belongs to the Release app.
enum CmuxAppLinks {
    /// The scheme the Chief writes.
    static let chiefScheme = "cmux"

    /// Runs `link.open` on `url` when ``link(for:linkScheme:chiefHost:)`` accepts it; false
    /// (nothing runs) for any other URL.
    @MainActor
    @discardableResult
    static func open(_ url: URL, services: AppServices) -> Bool {
        guard let link = link(for: url, linkScheme: services.linkScheme, chiefHost: services.agentTabs.chiefHost),
              let text = link.url(scheme: services.linkScheme)?.absoluteString else { return false }
        return services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(text)], origin: .user))
    }

    /// The link `url` opens in this app, in the `cmux` scheme or `linkScheme` (this build's): a
    /// workspace, pane, tab or chat session; a Chief subagent's chat only for this app's own
    /// Chief home (`chiefHost`, `chief:<home id>`) and on this machine. Nil for anything else (an
    /// unknown scheme or host, a malformed id, a legacy UUID link, another Chief's subagent).
    static func link(for url: URL, linkScheme: String, chiefHost: String?) -> DeepLink? {
        guard let link = DeepLink.parse(url, scheme: chiefScheme) ?? DeepLink.parse(url, scheme: linkScheme) else { return nil }
        switch link.target {
        case .workspace, .pane, .tab, .session:
            return link
        case .chiefSession(let home, _):
            return link.machine == nil && chiefHost == "chief:" + home ? link : nil
        case .legacyWorkspace, .legacyPane, .legacySurface:
            return nil
        }
    }
}

import CmuxNextActions
import CmuxNextLayout
import CmuxNextPages
import Foundation
import CmuxNextWakeups
import CmuxNextCompat
import CmuxNextDesign

/// A click on a cmux app link in rendered Markdown (the Home transcript, an agent chat, a
/// Markdown file page) or a terminal: a path (`file:///…`, ``openPath(_:services:)``),
/// `cmux://workspace/<ws_…>`, `pane/<pane_…>`, `tab/<tab_…>`,
/// `session/<id>`, or a Chief subagent's `chief/<home id>/session/<id>` (optchat-chief
/// `workspaces::subagent_link`). The Chief and its documents write the `cmux` scheme whatever the
/// build, so the link is opened as this build's `link.open` (the one shared path) and never goes
/// to another app through the system: the plain `cmux` scheme belongs to the Release app.
enum CmuxAppLinks {
    /// Runs `link.open` on `url` when ``link(for:linkScheme:chiefHost:)`` accepts it; false
    /// (nothing runs) for any other URL. `click`: how it was clicked (Cmd-click, Shift-Cmd, its tab).
    @MainActor
    @discardableResult
    static func open(_ url: URL, services: AppServices, click: LinkRouter.Click = .init()) -> Bool {
        if url.isFileURL { return openPath(url, services: services) }
        if let action = settingsAction(for: url, linkScheme: services.linkScheme) {
            return services.registry.perform(action, invocation: ActionInvocation(origin: .user))
        }
        if let agent = openAgentWeb(url, services: services, click: click) { return agent }
        // A pull request link clicked in an agent chat: the native GitHub page, not github.com.
        if !click.otherTarget, !click.background, let tab = click.source, services.agentTabs.isAgentTab(tab),
           let pane = services.linkOpener.source(tab: tab), let opened = WebPageTab.openGitHub(url, from: pane, services: services) { return opened }
        guard let link = link(for: url, linkScheme: services.linkScheme, chiefHost: services.agentTabs.chiefHost),
              let text = link.url(scheme: services.linkScheme)?.absoluteString else { return false }
        return services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(text)], origin: .user))
    }

    /// An agent session link's web form (`https://cmux.com/deeplink/agent?harness=&session=…`, or
    /// `?host=&session=` with no harness) clicked in the app opens the chat here, with no question
    /// since the person clicked it in cmux; only a chat acpmux does not list (not theirs) opens its
    /// web page, where `click` would have sent it (Cmd-click in the background, Shift-Cmd the other
    /// browser, beside its tab). A Cmd-click opens the chat without taking the keys. Nil for any other
    /// URL; false with agent links off.
    @MainActor
    static func openAgentWeb(_ url: URL, services: AppServices, click: LinkRouter.Click = .init()) -> Bool? {
        let (link, bare) = (DeepLink.parseAgentWeb(url), DeepLink.agentWebSession(url))
        guard link != nil || bare != nil else { return nil }
        let web = { @MainActor in LinkRouter.shared.open(url, as: click) }
        let intent: WindowActivation.Intent = click.background ? .bringForward : .raise
        return (try? DeepLinkNavigator(services: services).openAgentLink(link, bare: bare, intent, asking: false, notFound: web)) != nil
    }

    /// A path link (`file:///…`: Home's form of a path an agent wrote): a file opens in the
    /// file pages, a folder in a terminal started there, both beside the focused pane
    /// (``LinkOpener``, which shows why a file cannot open). Never handed to the system. The disk check
    /// runs off the main thread, after the click returns. False for a URL that is no
    /// absolute file path.
    @MainActor
    static func openPath(_ url: URL, services: AppServices) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        let path = url.standardizedFileURL.path
        let work = services.work
        // task-owner: one disk check, then one open
        Task { @MainActor [weak services] in
            // A person clicked the link: the disk check runs on the files lane at userBlocking (a stalled volume
            // holds a lane thread, never a cooperative-pool one).
            let isDirectory = (try? await work.run(.userBlocking, mayBlock: .files) { () -> Bool in
                var directory: ObjCBool = false
                return FileManager.checked.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            }) ?? false
            guard let services else { return }
            // Beside the pane the link was clicked from (LinkOpener): the pinned Home column, which
            // takes no tabs, gets the pane on its right or a new split.
            let source = services.windows.active?.focusedPane
            if isDirectory {
                services.linkOpener.openFolder(path, from: source)
            } else {
                services.linkOpener.openFile(URL(fileURLWithPath: path), from: source)
            }
        }
        return true
    }

    /// The action a settings link runs (``DeepLink/settingsAction(for:linkScheme:)``).
    static func settingsAction(for url: URL, linkScheme: String) -> ActionID? { DeepLink.settingsAction(for: url, linkScheme: linkScheme) }

    /// The link `url` opens in this app (``DeepLink/appLink(for:linkScheme:chiefHost:)``).
    static func link(for url: URL, linkScheme: String, chiefHost: String?) -> DeepLink? {
        DeepLink.appLink(for: url, linkScheme: linkScheme, chiefHost: chiefHost)
    }
}

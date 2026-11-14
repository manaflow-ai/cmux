import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextFeedClient

/// The Feed page's native UI ops (plans/cmux-next/feed-page.md 2), run through
/// `cmux.app.action.run`: `feed.openItem {item}` opens what an item points at (nothing without an
/// item: the Inbox page is gone), and
/// `feed.githubAction {item, action, comment?}` opens a GitHub item, starts an agent on it or
/// types its `gh` command into a new terminal. Both read the item from the daemon by id
/// (`feed.item.get`), never from the caller, and only open user-requested tabs.
@MainActor
enum FeedGitHubActions {
    static func bind(into registry: ActionRegistry, services: AppServices) {
        registry.bindEffect("feed.openItem", effect: { [weak services] invocation in
            guard let services else { return .done }
            // Without an item there is nothing to open (the Inbox page is gone).
            guard let id = invocation["item"]?.stringValue, !id.isEmpty else { return .done }
            let feed = services.feed
            // action-wait-allow: the item's context lives in the daemon's feed client; nothing shows before it is read.
            return .waiting(.daemonEcho) { [weak services] in
                guard let item = try? await feed.daemon.items([id], confirmed: false).first, let services else { return nil }
                open(item, services: services)
                return nil
            }
        })
        registry.bindEffect("feed.githubAction", effect: { [weak services] invocation in
            guard let services, let id = invocation["item"]?.stringValue,
                  let action = invocation["action"]?.stringValue else { return .done }
            let comment = invocation["comment"]?.stringValue
            let feed = services.feed
            // action-wait-allow: the item's GitHub details live in the daemon's feed client; nothing shows before they are read.
            return .waiting(.daemonEcho) { [weak services] in
                guard let item = try? await feed.daemon.items([id], confirmed: false).first, let services else { return nil }
                perform(action, item: item, text: comment, services: services)
                return nil
            }
        })
    }

    /// Opens an item's source: its link (a pull request, a sign-in page) in the browser; else the
    /// sign-in's own tab, or the tab or chat that asked; else nothing.
    static func open(_ item: FeedDaemonItem, services: AppServices) {
        if let url = item.url ?? item.prompt?.url.flatMap(URL.init(string:)) {
            services.externalOpen.openWebLink(url)
            return
        }
        let store = services.daemon.store
        let at = item.context
        let tab = store.tab(reported: item.prompt?.browserTab ?? at?.browserTab ?? at?.tab, terminal: at?.terminal, agentSession: at?.acpSession)
        if let tab { services.revealTab(tab.id) }
    }

    private static func perform(_ action: String, item: FeedDaemonItem, text: String?, services: AppServices) {
        // Only an action the daemon offers for this item (its `github_actions`), never one the caller names.
        guard item.githubActions?.contains(action) == true else { return }
        guard let detail = item.github, let link = detail.url, let url = URL(string: link) else { return }
        switch action {
        case "open":
            services.externalOpen.openWebLink(url)
        case "start_agent":
            guard let pane = services.windows.active?.focusedPane else { return }
            let draft = "Review this GitHub pull request:\n\(url.absoluteString)\n\nTitle: \(detail.title ?? item.title ?? "")"
            let seed = AgentPaneSeed(cwd: nil, draft: draft)
            pane.openAgentTab(seed: AgentPaneSeedSource(seed))
        case "checkout":
            guard let number = detail.number, let branch = detail.branch, let repository = detail.repo else { return }
            guard let pane = services.windows.active?.focusedPane else { return }
            let root = (NSHomeDirectory() as NSString).appendingPathComponent(".config/cmux/github-worktrees")
            let slug = "\(repository.replacingOccurrences(of: "/", with: "-"))-pr-\(number)"
            let path = "\(root)/\(slug)"
            let command = "mkdir -p \(quote(root)) && if [ ! -d \(quote(path)) ]; then gh repo clone \(quote(repository)) \(quote(path)); fi; git -C \(quote(path)) fetch origin pull/\(number)/head:\(quote(branch)); git -C \(quote(path)) checkout \(quote(branch))"
            pane.newTerminalTab(cwd: nil, typing: command + "\n")
        case "approve":
            runGH("gh pr review \(quote(url.absoluteString)) --approve", in: services)
        case "comment":
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            runGH("gh pr comment \(quote(url.absoluteString)) --body \(quote(text))", in: services)
        default:
            // Request changes waits for a comment editor that collects a review body.
            return
        }
    }

    private static func runGH(_ command: String, in services: AppServices) {
        guard let pane = services.windows.active?.focusedPane else { return }
        pane.newTerminalTab(cwd: nil, typing: command + "\n")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

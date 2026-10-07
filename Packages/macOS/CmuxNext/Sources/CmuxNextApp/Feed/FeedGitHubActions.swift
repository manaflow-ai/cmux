import AppKit
import CmuxNextAgentPane
import CmuxNextFeed

/// Host callbacks for explicit GitHub Inbox actions. The feed model remains a
/// projection; this service only opens user-requested tabs or runs `gh` in a
/// newly created terminal.
@MainActor
enum FeedGitHubActions {
    static func install(on model: FeedModel, services: AppServices) {
        model.onOpenItem = { [weak services] item in
            guard let services, let url = item.context.url else { return }
            services.externalOpen.open(url)
        }
        model.onAddConnection = { [weak services] in
            guard let services else { return }
            try? services.settingsWindow.show(section: .notifications, setting: "feed.github.enabled", focus: true)
        }
        model.githubActions = { [weak services] item in
            guard let services, item.dedupeKey?.hasPrefix("github:") == true,
                  let detail = services.feed.githubDetail(for: item), detail.url != nil else { return [] }
            var actions: Set<FeedGitHubAction> = [.open, .comment]
            if detail.number != nil, item.kind == "review" { actions.insert(.approve) }
            if detail.number != nil, detail.branch != nil, item.kind == "review" { actions.insert(.checkout) }
            if services.windows.active?.focusedPane != nil { actions.insert(.startAgent) }
            return actions
        }
        model.onGitHubAction = { [weak services, weak model] item, action, text in
            guard let services, let model else { return }
            perform(action, item: item, text: text, model: model, services: services)
        }
    }

    private static func perform(_ action: FeedGitHubAction, item: FeedItem, text: String?, model: FeedModel,
                                services: AppServices) {
        guard let detail = services.feed.githubDetail(for: item), let url = detail.url else { return }
        switch action {
        case .open:
            services.externalOpen.open(url)
        case .startAgent:
            guard let pane = services.windows.active?.focusedPane else { return }
            let draft = "Review this GitHub pull request:\n\(url.absoluteString)\n\nTitle: \(detail.title)"
            let seed = AgentPaneSeed(cwd: nil, draft: draft)
            pane.openAgentTab(seed: AgentPaneSeedSource(seed))
        case .checkout:
            guard let number = detail.number, let branch = detail.branch else { return }
            guard let pane = services.windows.active?.focusedPane else { return }
            let root = (NSHomeDirectory() as NSString).appendingPathComponent(".config/cmux/github-worktrees")
            let slug = "\(detail.repository.replacingOccurrences(of: "/", with: "-"))-pr-\(number)"
            let path = "\(root)/\(slug)"
            let command = "mkdir -p \(quote(root)) && if [ ! -d \(quote(path)) ]; then gh repo clone \(quote(detail.repository)) \(quote(path)); fi; git -C \(quote(path)) fetch origin pull/\(number)/head:\(quote(branch)); git -C \(quote(path)) checkout \(quote(branch))"
            pane.newTerminalTab(cwd: nil, typing: command + "\n")
        case .approve:
            runGH("gh pr review \(quote(url.absoluteString)) --approve", in: services)
        case .requestChanges:
            // The Inbox intentionally does not expose this action until its
            // comment editor can collect a review body.
            return
        case .comment:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            runGH("gh pr comment \(quote(url.absoluteString)) --body \(quote(text))", in: services)
        }
        model.githubActionError = nil
    }

    private static func runGH(_ command: String, in services: AppServices) {
        guard let pane = services.windows.active?.focusedPane else { return }
        pane.newTerminalTab(cwd: nil, typing: command + "\n")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

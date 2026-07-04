@testable import CmuxIssueInbox
import Foundation
import Testing

@Suite
struct IssueSpawnPlanTests {
    @Test
    func fullSpawnConfigBuildsAgentBrowserAndDevServerLayout() throws {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: IssueInboxSourceConfig(
                type: .github,
                repo: "manaflow-ai/cmux",
                projectRoot: "/repo",
                spawn: IssueInboxSpawnConfig(
                    devServerCommand: "cd webviews && bun dev",
                    webURL: "http://localhost:3000",
                    defaultAgent: .claude
                )
            ),
            workingDirectory: "/repo",
            requestedAgent: nil
        )

        #expect(plan.agent == .claude)
        guard case .split(let root) = plan.layout else {
            Issue.record("Expected root split")
            return
        }
        #expect(root.direction == .horizontal)
        #expect(root.split == 0.5)
        guard case .pane(let left) = root.children[0],
              let agentSurface = left.surfaces.first else {
            Issue.record("Expected left agent pane")
            return
        }
        #expect(agentSurface.type == .terminal)
        #expect(agentSurface.cwd == "/repo")
        #expect(agentSurface.focus == true)
        #expect(agentSurface.command == "claude 'Work on GitHub issue manaflow-ai/cmux#7256: Build Issue Inbox (https://github.com/manaflow-ai/cmux/issues/7256)'")

        guard case .split(let right) = root.children[1] else {
            Issue.record("Expected right split")
            return
        }
        #expect(right.direction == .vertical)
        guard case .pane(let browserPane) = right.children[0],
              case .pane(let devPane) = right.children[1] else {
            Issue.record("Expected browser and dev server panes")
            return
        }
        #expect(browserPane.surfaces.first?.type == .browser)
        #expect(browserPane.surfaces.first?.url == "http://localhost:3000")
        #expect(devPane.surfaces.first?.command == "cd webviews && bun dev")
        #expect(devPane.surfaces.first?.cwd == "/repo")
    }

    @Test
    func webOnlySpawnConfigUsesBrowserRightPane() throws {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: source(spawn: IssueInboxSpawnConfig(webURL: "http://localhost:5173")),
            workingDirectory: "/repo",
            requestedAgent: IssueSpawnAgent.none
        )

        guard case .split(let root) = plan.layout,
              case .pane(let left) = root.children[0],
              case .pane(let right) = root.children[1] else {
            Issue.record("Expected two-pane layout")
            return
        }
        #expect(left.surfaces.first?.command == nil)
        #expect(right.surfaces.first?.type == .browser)
        #expect(right.surfaces.first?.url == "http://localhost:5173")
    }

    @Test
    func devServerOnlySpawnConfigUsesTerminalRightPane() throws {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: source(spawn: IssueInboxSpawnConfig(devServerCommand: "bun dev")),
            workingDirectory: "/repo",
            requestedAgent: .codex
        )

        guard case .split(let root) = plan.layout,
              case .pane(let right) = root.children[1] else {
            Issue.record("Expected dev server right pane")
            return
        }
        #expect(right.surfaces.first?.type == .terminal)
        #expect(right.surfaces.first?.command == "bun dev")
    }

    @Test
    func noSpawnConfigWithAgentUsesSingleTerminalCommand() {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: source(spawn: nil),
            workingDirectory: "/repo",
            requestedAgent: .codex
        )

        #expect(plan.layout == nil)
        #expect(plan.initialCommand == "codex 'Work on GitHub issue manaflow-ai/cmux#7256: Build Issue Inbox (https://github.com/manaflow-ai/cmux/issues/7256)'")
    }

    @Test
    func noSpawnConfigWithNoAgentUsesCurrentSingleTerminalBehavior() {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: source(spawn: nil),
            workingDirectory: "/repo",
            requestedAgent: IssueSpawnAgent.none
        )

        #expect(plan.layout == nil)
        #expect(plan.initialCommand == nil)
    }

    @Test
    func agentCommandShellEscapesSingleQuotes() {
        let item = githubItem(title: "Fix Bob's workspace")
        let plan = IssueSpawnPlanBuilder.build(
            item: item,
            sourceConfig: source(spawn: nil),
            workingDirectory: "/repo",
            requestedAgent: .claude
        )

        #expect(plan.initialCommand == "claude 'Work on GitHub issue manaflow-ai/cmux#7256: Fix Bob'\\''s workspace (https://github.com/manaflow-ai/cmux/issues/7256)'")
    }

    @Test
    func agentCommandTemplateUsesShellEscapedPlaceholders() {
        let item = githubItem(title: "Fix Bob's workspace")
        let plan = IssueSpawnPlanBuilder.build(
            item: item,
            sourceConfig: source(spawn: IssueInboxSpawnConfig(
                defaultAgent: .codex,
                agentCommandTemplate: "codex --prompt {prompt} --title {title} --url {url} --number {number}"
            )),
            workingDirectory: "/repo",
            requestedAgent: nil
        )

        #expect(plan.initialCommand == "codex --prompt 'Work on GitHub issue manaflow-ai/cmux#7256: Fix Bob'\\''s workspace (https://github.com/manaflow-ai/cmux/issues/7256)' --title 'Fix Bob'\\''s workspace' --url 'https://github.com/manaflow-ai/cmux/issues/7256' --number '7256'")
    }

    @Test
    func planLayoutRoundTripsThroughJSON() throws {
        let plan = IssueSpawnPlanBuilder.build(
            item: githubItem(),
            sourceConfig: source(spawn: IssueInboxSpawnConfig(
                devServerCommand: "bun dev",
                webURL: "http://localhost:3000"
            )),
            workingDirectory: "/repo",
            requestedAgent: IssueSpawnAgent.none
        )

        let layout = try #require(plan.layout)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(IssueSpawnLayoutNode.self, from: data)
        #expect(decoded == layout)
    }

    private func source(spawn: IssueInboxSpawnConfig?) -> IssueInboxSourceConfig {
        IssueInboxSourceConfig(
            type: .github,
            repo: "manaflow-ai/cmux",
            projectRoot: "/repo",
            spawn: spawn
        )
    }

    private func githubItem(title: String = "Build Issue Inbox") -> IssueInboxItem {
        IssueInboxItem(
            id: "github:manaflow-ai/cmux:7256",
            provider: .github,
            sourceURL: URL(string: "https://github.com/manaflow-ai/cmux/issues/7256")!,
            title: title,
            status: .open,
            providerState: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            repoOrProject: "manaflow-ai/cmux",
            number: "7256",
            assignees: ["lawrence"],
            labels: ["feature"]
        )
    }
}

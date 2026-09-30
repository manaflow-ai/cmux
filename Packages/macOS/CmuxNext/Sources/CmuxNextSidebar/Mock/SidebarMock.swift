import CmuxNextDesign
import Foundation

/// Demo data: 40 workspaces across a pinned area, a local machine with
/// groups, and one cloud VM. Lets the module run without a daemon.
public enum SidebarMock {
    public static let cloudMachine = MachineID("vm-freestyle-a1")

    public static func makeModel() -> SidebarModel {
        let sections = makeSections()
        let model = SidebarModel(sections: sections, activeWorkspaceID: WorkspaceID("ws-local-3"))
        var counter = 0
        model.onIntent = { [weak model] intent in
            guard let model else { return }
            if case let .newWorkspace(machine, group) = intent {
                counter += 1
                let machineID = machine ?? model.activeWorkspaceID.flatMap { model.workspace($0)?.machineID } ?? .local
                let ws = SidebarWorkspace(
                    id: WorkspaceID("ws-new-\(counter)"),
                    machineID: machineID,
                    title: "Workspace \(counter)",
                    subtitle: "~"
                )
                insert(ws, into: model, group: group)
                model.click(ws.id)
                return
            }
            model.apply(intent)
        }
        return model
    }

    /// Scale fixture: `count` workspaces in groups of 10 on one machine.
    public static func makeLargeModel(count: Int) -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var nodes: [SidebarNode] = []
        var made = 0
        var groupIndex = 0
        while made < count {
            let size = min(10, count - made)
            let items = (0..<size).map { i in
                SidebarWorkspace(
                    id: WorkspaceID("ws-\(made + i)"),
                    title: "workspace \(made + i)",
                    subtitle: i.isMultiple(of: 2) ? "~/src/project-\(made + i)" : nil,
                    activity: i == 3 ? .running : .idle
                )
            }
            made += size
            if groupIndex.isMultiple(of: 3) {
                nodes.append(contentsOf: items.map(SidebarNode.workspace))
            } else {
                let color = GroupColor.allCases[groupIndex % GroupColor.allCases.count]
                nodes.append(.group(SidebarGroup(id: GroupID("grp-\(groupIndex)"), name: "group \(groupIndex)", color: color, workspaces: items)))
            }
            groupIndex += 1
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("ws-0"))
        return model
    }

    static func insert(_ ws: SidebarWorkspace, into model: SidebarModel, group: GroupID?) {
        guard let s = model.sections.firstIndex(where: { $0.id == .machine(ws.machineID) }) else { return }
        if let group, let n = model.sections[s].nodes.firstIndex(where: { $0.id == .group(group) }),
           case var .group(g) = model.sections[s].nodes[n] {
            g.workspaces.append(ws)
            model.sections[s].nodes[n] = .group(g)
        } else {
            model.sections[s].nodes.append(.workspace(ws))
        }
    }

    public static func makeSections() -> [SidebarSection] {
        let local = MachineID.local
        let cloud = cloudMachine
        func ws(
            _ id: String, _ machine: MachineID, _ title: String, _ subtitle: String?,
            _ icon: WorkspaceIcon? = nil, unread: UnreadState = .none, activity: AgentActivity = .idle
        ) -> SidebarWorkspace {
            // Agent lines are live status; everything else is passive detail.
            let isAgentLine = subtitle.map { $0.hasPrefix("Claude:") || $0.hasPrefix("Codex:") } ?? false
            return SidebarWorkspace(
                id: WorkspaceID(id), machineID: machine, title: title,
                subtitle: isAgentLine ? nil : subtitle, status: isAgentLine ? subtitle : nil,
                icon: icon, unread: unread, activity: activity
            )
        }

        let pinned = SidebarSection(kind: .pinned, nodes: [
            .workspace(ws("ws-pin-1", local, "hq", "~/fun/cmuxterm-hq  main", .symbol("house"))),
            .workspace(ws("ws-pin-2", local, "dotfiles", "~/.config", .symbol("gearshape"))),
            .workspace(ws("ws-pin-3", cloud, "prod logs", "tail -f axiom", .symbol("chart.line.uptrend.xyaxis"), unread: .dot)),
        ])

        let localSection = SidebarSection(kind: .machine(SidebarMachine(id: local, name: "This Mac", kind: .local)), nodes: [
            .workspace(ws("ws-local-1", local, "cmux", "worktrees/feat-cmux-next  feat-cmux-next", .swatch(.purple), activity: .running)),
            .workspace(ws("ws-local-2", local, "sidebar agent", "Claude: writing DropResolver.swift", .symbol("sparkles"), unread: .count(3), activity: .running)),
            .workspace(ws("ws-local-3", local, "tabs agent", "Codex: waiting for approval", .symbol("sparkles"), unread: .dot, activity: .needsInput)),
            .group(SidebarGroup(id: GroupID("grp-next"), name: "cmux-next", color: .purple, workspaces: [
                ws("ws-next-1", local, "daemon client", "feat-cmux-next-daemon-client", .symbol("antenna.radiowaves.left.and.right")),
                ws("ws-next-2", local, "terminal host", "feat-cmux-next-terminal", .symbol("terminal"), activity: .running),
                ws("ws-next-3", local, "palette", "feat-cmux-next-palette", .symbol("command")),
                ws("ws-next-4", local, "layout", "feat-cmux-next-layout", .symbol("rectangle.split.3x1")),
                ws("ws-next-5", local, "browser", "CEF fork build", .symbol("globe"), unread: .count(12), activity: .error),
            ])),
            .group(SidebarGroup(id: GroupID("grp-web"), name: "web", color: .green, workspaces: [
                ws("ws-web-1", local, "next dev", "bun dev  :3812", .symbol("bolt")),
                ws("ws-web-2", local, "drizzle", "web/db  migrations", .symbol("cylinder")),
                ws("ws-web-3", local, "vercel logs", "vercel logs --follow", .symbol("doc.text.magnifyingglass")),
            ])),
            .workspace(ws("ws-local-4", local, "ghostty", "ghostty  manaflow/main", .swatch(.orange))),
            .group(SidebarGroup(id: GroupID("grp-infra"), name: "infra", color: .orange, isCollapsed: true, workspaces: [
                ws("ws-infra-1", local, "fleet", "cmux-ci wait 4812", .symbol("server.rack"), activity: .running),
                ws("ws-infra-2", local, "tailscale", "tsadmin devices", .symbol("network")),
                ws("ws-infra-3", local, "subrouter", "cmux-lawrence:31415", .symbol("arrow.triangle.branch"), unread: .count(2)),
                ws("ws-infra-4", local, "pscale", "cmux-prod  staging", .symbol("cylinder.split.1x2")),
            ])),
            .workspace(ws("ws-local-5", local, "zed", "zed/repo  main", .swatch(.cyan))),
            .workspace(ws("ws-local-6", local, "notes", "~/notes", .symbol("note.text"))),
            .workspace(ws("ws-local-7", local, "iOS sim", "ios/scripts/reload.sh", .symbol("iphone"))),
            .group(SidebarGroup(id: GroupID("grp-reviews"), name: "reviews", color: .pink, workspaces: [
                ws("ws-rev-1", local, "PR 12842", "termio write pool", .symbol("checkmark.seal")),
                ws("ws-rev-2", local, "PR 12910", "sidebar groups", .symbol("checkmark.seal"), unread: .dot),
                ws("ws-rev-3", local, "PR 12933", "iroh relay retry", .symbol("checkmark.seal")),
            ])),
            .workspace(ws("ws-local-8", local, "htop", nil, .symbol("gauge.with.dots.needle.67percent"))),
            .workspace(ws("ws-local-9", local, "scratch", "/tmp", .swatch(.grey))),
            .workspace(ws("ws-local-10", local, "chatmux", "~/fun/chatmux  v2", .symbol("bubble.left.and.bubble.right"))),
        ])

        let cloudSection = SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "cloud-a1", kind: .cloud)), nodes: [
            .workspace(ws("ws-cloud-1", cloud, "agent: migrate db", "Claude: running drizzle push", .symbol("sparkles"), activity: .running)),
            .workspace(ws("ws-cloud-2", cloud, "agent: fix flaky test", "Codex: needs input", .symbol("sparkles"), unread: .count(1), activity: .needsInput)),
            .group(SidebarGroup(id: GroupID("grp-cloud-bench"), name: "benchmarks", color: .cyan, workspaces: [
                ws("ws-cloud-3", cloud, "npm install", "sandbox-fs-bench", .symbol("shippingbox")),
                ws("ws-cloud-4", cloud, "cargo build", "cmux-tui  release", .symbol("hammer"), activity: .running),
                ws("ws-cloud-5", cloud, "pip install", "sandbox-fs-bench", .symbol("shippingbox")),
            ])),
            .workspace(ws("ws-cloud-6", cloud, "docker", "docker compose up", .symbol("cube"))),
            .workspace(ws("ws-cloud-7", cloud, "postgres", "psql cmux", .symbol("cylinder"))),
            .workspace(ws("ws-cloud-8", cloud, "shell", "~", .swatch(.blue))),
            .workspace(ws("ws-cloud-9", cloud, "logs", "journalctl -f", .symbol("text.alignleft"))),
            .workspace(ws("ws-cloud-10", cloud, "tui", "cmux-tui --session cloud", .symbol("rectangle.3.group"))),
            .workspace(ws("ws-cloud-11", cloud, "redis", "redis-cli monitor", .symbol("memorychip"))),
            .workspace(ws("ws-cloud-12", cloud, "nix build", "nix build .#cmux-tui", .symbol("snowflake"), activity: .running)),
        ])

        return [pinned, localSection, cloudSection]
    }
}

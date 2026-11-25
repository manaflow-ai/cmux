#if DEBUG
public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources

/// DEBUG ONLY: the workspace hover card in each of its kinds over fixture data, for the hover card
/// gallery (`debug.hover_cards {gallery}`, HoverCardGallery, the macOS tour's `hover-card` shots; Leo 2026-10-19, the
/// Codex sidebar card and Claude desktop's PR list). The words are fixture data, like a mock's.
public struct WorkspaceHoverCardGallery {
    public init() {}
    /// Each state's name and its card on the overlay glass, configured; resources sampled a few
    /// times so the CPU bars show.
    @MainActor public static func cards(now: Date = Date()) -> [(name: String, view: NSView)] {
        let mixedTabs = [
                SidebarTab(id: TabID("terminal"), title: "app", kind: .terminal, folder: "~", state: .success),
                SidebarTab(id: TabID("claude"), title: "Claude Code", kind: .agentChat, folder: "~/Projects/cmux", state: .working),
                SidebarTab(id: TabID("review"), title: "Review changes", kind: .conversation, folder: "~/Projects/cmux", state: .waiting),
        ]
        typealias Fact = WorkspaceHoverCardContent.Fact
        let agent = Fact(icon: .agentChat, text: "Codex · gpt-6.1-sol", kind: "agent")
        let folder = Fact(icon: .folder, text: "docs", kind: "folder")
        // The repository and branch on one line (Leo 2026-10-21); a home folder is no line at all.
        let branch = Fact(icon: .gitBranch, text: "cmux · feat/shared-hover-card", kind: "branch")
        let reply = Fact(icon: .agentChatList, text: "Done: the tab and session cards share one row now, with the PR status in color.",
                         lines: 2, kind: Fact.lastReplyKind, isPreview: true)
        // What the agent chat carries per call and spent in 24 hours (acpmux `usageStats`).
        let usage = Fact(icon: .contextUsage, text: "312K context · $1,421 in 24h", kind: "usage", accessory: .ring(0.31, tone: .secondary))
        // A pull request as the card's preview: its state in color, the icon in that color too.
        func pr(_ status: String, _ tone: HoverCardTone, adds: Int, dels: Int, preview: Bool = true) -> Fact {
            Fact(icon: .gitPullrequest, text: "#22231 Share one hover card row", kind: "pullRequest", status: status, statusTone: tone,
                 additions: adds, deletions: dels, iconTone: tone, isPreview: preview)
        }
        // A made-up machine name: the capture's privacy check refuses a real host's.
        let machine = Fact(icon: .machineRemote, text: "dev-mini", kind: "machine", accessory: .dot(.danger))
        let offline = Fact(icon: .statusDisconnected, text: "Remote environment is offline", kind: "machineStatus", ink: .danger)
        let states: [(String, WorkspaceHoverCardContent, [Double])] = [
            ("Agent running", WorkspaceHoverCardContent(
                title: "Make the hover cards look like Codex's", icon: .agentChat, age: "3m",
                facts: [agent, usage, branch, pr("Checks running", .attention, adds: 412, dels: 96)],
                activity: .working, activitySince: now.addingTimeInterval(-192)), [0.4, 0.9, 1.3, 1.8, 2.2, 1.6, 2.4]),
            ("Agent idle", WorkspaceHoverCardContent(
                title: "Fix the session hover card", icon: .agentChat, age: "1d",
                facts: [agent, branch, reply]), []),
            // A chat that never left the home folder: the name, then the last reply on its icon's line.
            ("Chat at home", WorkspaceHoverCardContent(
                title: "web-ota", icon: .agentChat, age: "2h",
                facts: [reply]), []),
            ("Remote offline", WorkspaceHoverCardContent(
                title: "Deploy the docs", icon: .machineRemote, age: "2h",
                facts: [folder, machine, offline]), []),
            ("PR conflict", WorkspaceHoverCardContent(
                title: "Sidebar rows badge their logo's corner", icon: .agentChat, age: "5h",
                facts: [branch, pr("Conflict", .attention, adds: 88, dels: 31, preview: false),
                        pr("Checks failed", .danger, adds: 88, dels: 31)]), []),
            ("PR merged", WorkspaceHoverCardContent(
                title: "Overlays are themed Liquid Glass", icon: .agentChat, age: "4w",
                facts: [branch, pr("Merged", .merged, adds: 69, dels: 32)]), []),
        ]
        let richCards = states.map { name, content, cpu in
            let card = WorkspaceHoverCardView()
            card.configure(content, now: now)
            card.detailsToggle.performClick(nil)
            for value in cpu {
                card.setResources(ResourceReport(total: ResourceUsage(cpu: value, memoryBytes: 2_300 << 20), processCount: 6))
            }
            return (name, HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
        }
        let content = WorkspaceHoverCardContent(
            title: "Review the sidebar", icon: .agentChat, age: "3m",
            facts: [agent, branch, reply], activity: .working, activitySince: now.addingTimeInterval(-192))
        let overflow = mixedTabs + (1...4).map {
            SidebarTab(id: TabID("docs-\($0)"), title: "Documentation \($0)", kind: .browser, state: .success)
        }
        let variants: [(String, WorkspaceHoverCardView.TabPlacement, Int, Bool, Bool)] = [
            ("Tabs after status · 4 + more", .afterStatus, 4, true, true),
            ("Tabs below title · 3 + more", .afterTitle, 3, true, true),
            ("Tabs below details · 6 compact + more", .afterDetails, 6, false, true),
            ("Tabs first · details collapsed · chosen", .afterTitle, 4, true, false),
        ]
        let tabCards = variants.map { name, placement, limit, details, expanded in
            let card = WorkspaceHoverCardView(tabPlacement: placement, style: WorkspaceTabHoverCardStyle(twoLines: details, rowLimit: limit))
            card.configure(content, now: now)
            card.configureTabs(title: content.title, tabs: overflow, now: now)
            if expanded { card.detailsToggle.performClick(nil) }
            return (name, HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
        }
        return tabCards + tabRowCards(now: now) + [cloudCard(now: now)] + closeAndSpinnerCards(now: now) + workCards(now: now) + richCards
    }

    /// A Cloud workspace with one terminal (Leo 2026-11-02, on a card that said Cloud four times: "isn't this
    /// extremely stupid looking?" / "the tiny cloud icon the repeated cloud cloud cloud"): the header names the
    /// machine once beside the title, its dot beside it, and the terminal's row does not repeat it.
    @MainActor static func cloudCard(now: Date) -> (name: String, view: NSView) {
        // A made-up machine name: the capture's privacy check refuses a real host's.
        let cloud = SidebarMachine(id: MachineID("cloud-a"), name: "cloud-a", kind: .cloud, status: .connected)
        var workspace = SidebarWorkspace(id: WorkspaceID("cloud-ws"), machineID: cloud.id, title: "workspace-2")
        workspace.tabs = [SidebarTab(id: TabID("terminal"), title: "Terminal", kind: .terminal)]
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: cloud, now: now), now: now)
        card.configureTabs(title: workspace.title, tabs: workspace.tabs, now: now, machine: cloud)
        return ("Cloud workspace · machine named once · chosen", HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
    }

    /// Leo 2026-11-02: "YOU SHOULD BE ABLE TO CLOSE THESE TABS FROM THE HOVER PREVIEW" / "PLUS THE PLACEMENT LOOKS
    /// LIKE SHIT". A working lane chat with its subagents and commands: its short session name, the spinner after
    /// the title, a meta line with no "Working"; once at rest and once with its row hovered, showing the ✕.
    @MainActor static func closeAndSpinnerCards(now: Date) -> [(name: String, view: NSView)] {
        var chat = SidebarTab(id: TabID("lane"), title: "lane-vm-11/nightly-rollback", kind: .agentChat, brand: "codex",
                              folder: "~/Projects/cmux", state: .working, lastActivity: now.addingTimeInterval(-120))
        chat.model = "gpt-6.1-sol"
        chat.subagentsRunning = 2
        chat.commandsRunning = 2
        var shell = SidebarTab(id: TabID("shell"), title: "~", kind: .terminal, folder: "~")
        shell.command = "npm test"
        let tabs = [chat, shell, SidebarTab(id: TabID("done"), title: "Review changes", kind: .conversation, folder: "~/Projects/cmux",
                                            state: .success)]
        let local = SidebarMachine(id: .local, name: "studio", kind: .local)
        let content = WorkspaceHoverCardContent(title: "nightly-rollback", icon: .agentChat, facts: [])
        return [("Tab rows · spinner after the title · chosen", false), ("Tab rows · close ✕ on hover · chosen", true)].map { name, hovered in
            let card = WorkspaceHoverCardView()
            card.configure(content, now: now)
            card.configureTabs(title: content.title, tabs: tabs, now: now, machine: local)
            card.tabList.onClose = { _ in }
            if hovered { card.tabList.rowViews.first?.isHovered = true }
            return (name, HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
        }
    }

    /// The tab rows' line in each style (Leo 2026-11-01: "local or nonlocal is probably useful to see in the
    /// hover previews"; "these are not informative enough nor look very good. there's no symbols, not much
    /// metadata, nothing"), on this Mac and on another machine; the shipped one says so in its name. On another
    /// machine the card's header names it, so its rows name none (Leo 2026-11-02: "the repeated cloud cloud cloud").
    @MainActor static func tabRowCards(now: Date) -> [(name: String, view: NSView)] {
        var chat = SidebarTab(id: TabID("coord"), title: "claude-sr2-coord", kind: .agentChat, brand: "claude", folder: "~/Projects",
                              state: .working, lastActivity: now.addingTimeInterval(-60))
        chat.model = "claude-opus-5-5"
        chat.subagentsRunning = 2
        var shell = SidebarTab(id: TabID("shell"), title: "~", kind: .terminal, folder: "~")
        shell.command = "npm test"
        var pull = SidebarTab(id: TabID("pr"), title: "Hover card rows · Pull Request #12", kind: .browser, host: "github.com")
        pull.path = "/manaflow-ai/cmux/pull/12"
        var unloaded = SidebarTab(id: TabID("issues"), title: "github.com", kind: .browser, host: "github.com")
        unloaded.path = "/manaflow-ai/cmux/issues"
        let tabs = [chat, shell, pull, unloaded, SidebarTab(id: TabID("new"), title: Strings.hoverCardNewTab, kind: .newTab)]
        // A made-up machine name: the capture's privacy check refuses a real host's.
        let local = SidebarMachine(id: .local, name: "studio", kind: .local)
        let remote = SidebarMachine(id: MachineID("dev-mini"), name: "dev-mini", kind: .ssh)
        var everyLine = WorkspaceTabHoverCardStyle.standard
        everyLine.namesLocalMachine = true
        var trailing = WorkspaceTabHoverCardStyle.standard
        trailing.trailing = .machine
        var before = WorkspaceTabHoverCardStyle.standard
        before.detail = [.place, .state, .time]
        let variants: [(String, WorkspaceTabHoverCardStyle)] = [
            ("Tab rows · only another machine named · chosen", .standard),
            ("Tab rows · machine on every line", everyLine),
            ("Tab rows · machine in the trailing column", trailing),
            ("Tab rows · before (place · state · time)", before),
        ]
        let content = WorkspaceHoverCardContent(title: "claude-sr2-coord", icon: .agentChat, facts: [])
        return variants.flatMap { name, style in
            [(local, "this Mac"), (remote, "another machine")].map { machine, place in
                let card = WorkspaceHoverCardView(style: style)
                card.configure(content, now: now)
                card.configureTabs(title: content.title, tabs: tabs, now: now, machine: machine)
                return ("\(name) · \(place)", HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
            }
        }
    }

    /// The expanded card with its agent's running work, in each `WorkspaceHoverCardWork.Style`
    /// (Leo 2026-11-01: "this hover preview being able to see the # of associated subagents and
    /// whatnot"); the shipped one says so in its name. Its History holds no inbox notice.
    @MainActor static func workCards(now: Date) -> [(name: String, view: NSView)] {
        var detail = SidebarWorkspaceDetail()
        detail.subagentsRunning = 3
        detail.commandsRunning = 1
        detail.subagentNames = ["Review the hover card", "Fix the sidebar test", "Gallery captures"]
        var chat = SidebarTab(id: TabID("lead"), title: "dev-lane/ui-lead", kind: .agentChat, folder: "~/Projects/cmux", state: .working)
        chat.subagentsRunning = 3
        chat.commandsRunning = 1
        let timeline = [
            SidebarTimelineEntry(kind: .prompt, date: now.addingTimeInterval(-60), text: "Land the hover card change", agent: "Claude Code"),
            SidebarTimelineEntry(kind: .prompt, date: now.addingTimeInterval(-900), text: "Look at the sidebar previews", agent: "Claude Code"),
        ]
        return WorkspaceHoverCardWork.Style.allCases.map { style in
            var content = WorkspaceHoverCardContent(
                title: "UI lead", icon: .agentChat,
                facts: [WorkspaceHoverCardContent.Fact(icon: .agentChat, text: "Claude Code · claude-opus-5-5", kind: "agent")]
                    + WorkspaceHoverCardWork.facts(detail, style: style),
                activity: .working, activitySince: now.addingTimeInterval(-41))
            content.timeline = timeline
            content.stats = Strings.timelineStats(prompts: 2, worked: "26m 52s")
            let card = WorkspaceHoverCardView()
            card.configure(content, now: now)
            card.tabList.configure(title: content.title, tabs: [chat])
            card.detailsToggle.performClick(nil)
            let shipped = style == WorkspaceHoverCardWork.shipped ? " · chosen" : ""
            return ("Running work · \(style.rawValue)\(shipped)", HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
        }
    }

}
#endif

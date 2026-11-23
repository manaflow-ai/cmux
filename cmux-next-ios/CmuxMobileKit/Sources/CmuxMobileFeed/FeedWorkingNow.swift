#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import Observation
import SwiftUI

/// One agent that works right now: a card of the Feed's "Working now" strip.
struct WorkingAgent: Identifiable, Hashable, Sendable {
    var workspaceID: String
    var tabID: String
    var harness: String
    var agentName: String
    var workspaceTitle: String
    /// What the tab says the agent works on (`WorkspaceTab.task`), when it says more than the agent's name.
    var task: String?
    /// A terminal agent: a tap opens its terminal tab, not a chat.
    var opensTerminal: Bool
    /// When the Mac says it started working (`WorkspaceTab.workingSince`); nil shows no time.
    var since: Date?

    var id: String { workspaceID + "\u{1F}" + tabID }

    /// "workspace › tab", else the workspace alone.
    var place: String {
        guard let task, !task.isEmpty else { return workspaceTitle }
        return workspaceTitle.isEmpty ? task : "\(workspaceTitle) › \(task)"
    }

    /// Every working agent tab of `workspaces`, newest start first (no start time last), minus
    /// muted workspaces (the Feed's Filter menu) and Macs known to be offline: their last known
    /// "working" is not "right now".
    static func list(in workspaces: [Workspace], offlineMacs: Set<String> = [], muted: Set<String> = []) -> [WorkingAgent] {
        var agents: [WorkingAgent] = []
        for workspace in workspaces where !muted.contains(workspace.id) && !offlineMacs.contains(workspace.macID) {
            for tab in workspace.tabs where tab.agentStatus == .working && tab.isAgent {
                agents.append(WorkingAgent(
                    workspaceID: workspace.id, tabID: tab.id, harness: tab.harness ?? "", agentName: tab.agentName,
                    workspaceTitle: workspace.title, task: tab.task, opensTerminal: tab.kind != .agent, since: tab.workingSince
                ))
            }
        }
        // Stable: the same agents keep the same order whatever order the Macs list their workspaces in.
        return agents.sorted { a, b in
            switch (a.since, b.since) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.id < b.id
            }
        }
    }
}

/// The agents working right now, for the Feed's strip. It follows the app's workspaces on its own
/// (Observation, outside any view): a Mac tree update that changes no agent's working state
/// publishes nothing, so neither the strip nor the Feed screen draws again for it.
@MainActor
@Observable
final class FeedWorkingNow {
    static let shared = FeedWorkingNow()

    /// Changes only when the working set (or a capsule's text or start time) does.
    private(set) var agents: [WorkingAgent] = []
    /// Changes only when the strip appears or goes: what the Feed screen reads (its header's height).
    private(set) var isShowing = false

    @ObservationIgnored private weak var appStore: AppStore?
    @ObservationIgnored private var generation = 0

    /// Follows `appStore`'s workspaces and Macs and the Feed's muted workspaces. Idempotent per store.
    func follow(_ appStore: AppStore, feed: FeedStore) {
        guard self.appStore !== appStore else { return }
        self.appStore = appStore
        generation += 1
        refresh(appStore, feed: feed, generation: generation)
    }

    private func refresh(_ appStore: AppStore, feed: FeedStore, generation: Int) {
        // One pass over the tabs per change; a burst of tree updates in one turn is one pass
        // (the tracking fires once, and the next pass arms it again).
        let next: [WorkingAgent] = withObservationTracking {
            #if DEBUG
            if let mock = Self.mockAgents { return mock }
            #endif
            let offline = Set(appStore.teams.flatMap(\.macs).filter { !$0.isOnline }.map(\.id))
            return WorkingAgent.list(in: appStore.workspaces, offlineMacs: offline, muted: feed.mutedWorkspaces)
        } onChange: { [weak self, weak appStore, weak feed] in
            Task { @MainActor in
                guard let self, let appStore, let feed, self.generation == generation else { return }
                self.refresh(appStore, feed: feed, generation: generation)
            }
        }
        if next != agents { agents = next }
        if isShowing != !next.isEmpty { isShowing = !next.isEmpty }
    }

    #if DEBUG
    /// Screenshot rig: `CMUX_MOBILE_FEED_WORKING_MOCK=1` shows three working agents of the mock
    /// workspaces with start times (the mock workspaces carry none); `=0` shows none.
    private static let mockAgents: [WorkingAgent]? = {
        switch ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_WORKING_MOCK"] {
        case "1":
            let now = Date()
            return [
                WorkingAgent(workspaceID: "ws-web", tabID: "t-codex", harness: "codex", agentName: "Codex", workspaceTitle: "cmux.com",
                             task: "Fix pricing page layout", opensTerminal: false, since: now.addingTimeInterval(-42)),
                WorkingAgent(workspaceID: "ws-ios", tabID: "t-ios-claude", harness: "claude", agentName: "Claude", workspaceTitle: "cmux-next-ios",
                             task: "Redesign the workspaces list", opensTerminal: false, since: now.addingTimeInterval(-247)),
                WorkingAgent(workspaceID: "ws-infra", tabID: "t-htop", harness: "claude", agentName: "Claude", workspaceTitle: "fleet",
                             task: "Audit runner labels", opensTerminal: true, since: now.addingTimeInterval(-4350)),
            ]
        case "0": return []
        default: return nil
        }
    }()
    #endif
}

/// The Feed's "Working now" strip: one horizontally scrolling row of the agents working right
/// now across every workspace. Each capsule opens its chat (a terminal agent's: its terminal
/// tab). Nothing when no agent works. It reads only `FeedWorkingNow.agents`.
struct FeedWorkingStrip: View {
    let model: FeedWorkingNow
    let open: (WorkingAgent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.agents.isEmpty {
                ScrollView(.horizontal) {
                    // Lazy: with many agents working, only the capsules on screen exist (and spin).
                    LazyHStack(spacing: 8) {
                        ForEach(model.agents) { agent in
                            Button { open(agent) } label: { WorkingAgentCapsule(agent: agent) }
                                .buttonStyle(.cmuxPressFillInLabel)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    // 16 pt: the first capsule shares the chips' and the rows' avatars' left edge.
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .trailingOverflowFade(width: 32)
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Working now")
                .accessibilityIdentifier("feed.workingNow")
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.cmuxMobileSnappy.unlessReduceMotion, value: model.agents.map(\.id))
    }
}

private struct WorkingAgentCapsule: View {
    let agent: WorkingAgent
    /// Two cards and the edge of a third fit an iPhone's width, so a glance says "there are more".
    @ScaledMetric(relativeTo: .footnote) private var textWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: FeedRowCell.avatarSymbol(agent.harness))
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 16, alignment: .leading)
                Text(agent.workspaceTitle.isEmpty ? agent.agentName : agent.workspaceTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                CmuxSpinner(size: 12)
            }
            HStack(spacing: 6) {
                Text(agent.task.flatMap { $0.isEmpty ? nil : $0 } ?? agent.agentName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let since = agent.since {
                    // A system-driven timer: it counts up without a view update per second.
                    Text(since, style: .timer)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        // A timer text takes every point offered; its own width leaves the rest to the task.
                        .fixedSize()
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: textWidth)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cmuxMobilePressBackground(Color.cmuxMobileFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.agentName) is working in \(agent.place)")
        .accessibilityValue(agent.since.map { Text($0, style: .relative) } ?? Text(""))
        .accessibilityHint(agent.opensTerminal ? "Opens its terminal" : "Opens its chat")
        .accessibilityAddTraits(.isButton)
    }
}
#endif

#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// The Feed tab's visible filter: everything, or only rows awaiting input.
enum AgentFeedFilter: Hashable {
    case all
    case needsInput
}

/// The store-free Feed presentation: an X-style full-width timeline of agent
/// activity with inline output and inline decision controls. Distinct from
/// the Notifications tab, which stays a read/unread notification list.
struct AgentFeedView: View {
    let items: [MobileAgentFeedItem]
    let status: MobileNotificationFeedStatus
    let pendingReplyRequestIDs: Set<String>
    let refreshesOnAppear: Bool
    let actions: AgentFeedActions
    @State private var filter: AgentFeedFilter = .all
    @State private var now = Date()
    @State private var composeContext: AgentFeedComposeContext?

    /// Row actions with the composer hook bound to this view's sheet state.
    private var rowActions: AgentFeedActions {
        var rowActions = actions
        rowActions.beginCompose = { item, kind in
            composeContext = AgentFeedComposeContext(item: item, kind: kind)
        }
        return rowActions
    }

    private var visibleItems: [MobileAgentFeedItem] {
        // The Feed is a decision surface: routine tool churn and the user's
        // own prompts stay out even when an older Mac still sends them (a
        // prompt shows as the quoted context line under agent rows instead);
        // failed tool results are notable and stay visible.
        let notable = items.filter { item in
            switch item.kind {
            case .toolUse, .userPrompt:
                return false
            case .toolResult:
                return item.toolResultIsError
            case .permissionRequest, .exitPlan, .question,
                 .assistantMessage, .stop, .todos, .unsupported:
                return true
            }
        }
        switch filter {
        case .all:
            return notable
        case .needsInput:
            return notable.filter(\.needsInput)
        }
    }

    private var needsInputCount: Int {
        items.lazy.filter(\.needsInput).count
    }

    var body: some View {
        Group {
            switch status {
            case .idle, .loading where items.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable where items.isEmpty:
                AgentFeedUnavailableView()
            case .requiresMacUpdate where items.isEmpty:
                AgentFeedRequiresMacUpdateView()
            default:
                feedList
            }
        }
        // The Feed carries no navigation title: the timeline itself is the
        // header, and the toolbar hosts only the filter menu.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AgentFeedFilterMenu(
                    filter: filter,
                    needsInputCount: needsInputCount,
                    setFilter: { filter = $0 }
                )
            }
        }
        .sheet(item: $composeContext) { context in
            AgentFeedReplyComposer(context: context, actions: actions)
        }
        .onAppear {
            now = Date()
            guard refreshesOnAppear else { return }
            Task { await actions.refresh() }
        }
    }

    private var feedList: some View {
        List {
            Section {
                if visibleItems.isEmpty {
                    AgentFeedEmptyView(filter: filter)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(visibleItems, id: \.id) { item in
                        AgentFeedRow(
                            model: AgentFeedRowModel(item: item),
                            isReplyPending: item.requestID.map {
                                pendingReplyRequestIDs.contains($0)
                            } ?? false,
                            now: now,
                            actions: rowActions
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        // X-style: hairlines run BETWEEN posts only — no
                        // divider above the first row.
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(.visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
            }
        }
        .listStyle(.plain)
        // Swiping the feed lowers the keyboard, so an abandoned inline reply
        // never pins it over the timeline.
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            now = Date()
            await actions.refresh()
        }
    }

}

/// The Feed's filter as a toolbar menu, mirroring the Workspaces filter
/// control: a `Menu` hosting a picker, with the filled Mail-style icon while
/// a narrowing filter is active.
private struct AgentFeedFilterMenu: View {
    let filter: AgentFeedFilter
    let needsInputCount: Int
    let setFilter: (AgentFeedFilter) -> Void

    var body: some View {
        Menu {
            Picker(
                String(
                    localized: "mobile.agentFeed.filter",
                    defaultValue: "Filter",
                    bundle: .module
                ),
                selection: Binding(get: { filter }, set: { setFilter($0) })
            ) {
                Text(String(
                    localized: "mobile.agentFeed.filter.all",
                    defaultValue: "All Activity",
                    bundle: .module
                ))
                .tag(AgentFeedFilter.all)
                Text(
                    needsInputCount > 0
                        ? String(
                            localized: "mobile.agentFeed.filter.needsInputCount",
                            defaultValue: "Needs Input (\(needsInputCount))",
                            bundle: .module
                        )
                        : String(
                            localized: "mobile.agentFeed.filter.needsInput",
                            defaultValue: "Needs Input",
                            bundle: .module
                        )
                )
                .tag(AgentFeedFilter.needsInput)
            }
        } label: {
            Image(systemName: filter == .needsInput
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(String(
            localized: "mobile.agentFeed.filter",
            defaultValue: "Filter",
            bundle: .module
        ))
        .accessibilityIdentifier("MobileAgentFeedFilterMenu")
    }
}

private struct AgentFeedEmptyView: View {
    let filter: AgentFeedFilter

    var body: some View {
        ContentUnavailableView(
            filter == .needsInput
                ? String(
                    localized: "mobile.agentFeed.empty.needsInput.title",
                    defaultValue: "Nothing Needs You",
                    bundle: .module
                )
                : String(
                    localized: "mobile.agentFeed.empty.all.title",
                    defaultValue: "No Agent Activity Yet",
                    bundle: .module
                ),
            systemImage: filter == .needsInput ? "checkmark.circle" : "waveform",
            description: Text(
                filter == .needsInput
                    ? String(
                        localized: "mobile.agentFeed.empty.needsInput.description",
                        defaultValue: "Agent questions, permission requests, and plan approvals will appear here the moment they need you.",
                        bundle: .module
                    )
                    : String(
                        localized: "mobile.agentFeed.empty.all.description",
                        defaultValue: "Run a coding agent in cmux on your Mac and its activity streams here.",
                        bundle: .module
                    )
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct AgentFeedUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            String(
                localized: "mobile.agentFeed.unavailable.title",
                defaultValue: "Feed Unavailable",
                bundle: .module
            ),
            systemImage: "wifi.slash",
            description: Text(String(
                localized: "mobile.agentFeed.unavailable.description",
                defaultValue: "Connect to a Mac to see its agent activity.",
                bundle: .module
            ))
        )
    }
}

private struct AgentFeedRequiresMacUpdateView: View {
    var body: some View {
        ContentUnavailableView(
            String(
                localized: "mobile.agentFeed.requiresUpdate.title",
                defaultValue: "Update cmux on Your Mac",
                bundle: .module
            ),
            systemImage: "arrow.triangle.2.circlepath",
            description: Text(String(
                localized: "mobile.agentFeed.requiresUpdate.description",
                defaultValue: "The connected Mac's cmux predates the agent Feed. Update it to stream agent activity here.",
                bundle: .module
            ))
        )
    }
}
#endif

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

    private var visibleItems: [MobileAgentFeedItem] {
        switch filter {
        case .all:
            return items
        case .needsInput:
            return items.filter(\.needsInput)
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
        .navigationTitle(String(
            localized: "mobile.agentFeed.title",
            defaultValue: "Feed",
            bundle: .module
        ))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            now = Date()
            guard refreshesOnAppear else { return }
            Task { await actions.refresh() }
        }
    }

    private var feedList: some View {
        List {
            Section {
                filterPicker
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
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
                            actions: actions
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.visible)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            now = Date()
            await actions.refresh()
        }
    }

    private var filterPicker: some View {
        Picker(
            String(
                localized: "mobile.agentFeed.filter",
                defaultValue: "Filter",
                bundle: .module
            ),
            selection: $filter
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
        .pickerStyle(.segmented)
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

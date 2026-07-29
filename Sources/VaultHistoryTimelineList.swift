import SwiftUI

/// Immutable list projection kept below History's lazy layout boundary.
struct VaultHistoryTimelineList: View {
    let groups: [VaultHistoryGroup]
    let resumeEntriesByEventId: [String: SessionEntry]
    let availableClosedItemIds: Set<UUID>
    let actions: VaultHistoryRowActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            VaultHistoryEventRow(
                                event: event,
                                action: rowAction(for: event),
                                actions: actions
                            )
                        }
                    } header: {
                        VaultHistoryGroupHeader(title: group.title, count: group.events.count)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowAction(for event: VaultHistoryEvent) -> VaultHistoryRowAction? {
        if let entry = resumeEntriesByEventId[event.id], actions.canResume {
            return .resumeSession(entry)
        }
        if let closedItemId = event.subject.closedItemId,
           availableClosedItemIds.contains(closedItemId),
           actions.canReopen {
            return .reopenClosedItem(closedItemId)
        }
        return nil
    }
}

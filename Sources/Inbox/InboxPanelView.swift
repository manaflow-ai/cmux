import CmuxFoundation
import CmuxInbox
import SwiftUI

struct InboxPanelView: View {
    // Optional on purpose: this panel renders inside AppKit-hosted
    // NSHostingView trees (per-window ContentView roots), and a hosting root
    // that misses the runtime injection must degrade instead of crashing.
    @Environment(InboxRuntime.self) private var runtime: InboxRuntime?

    var body: some View {
        if let runtime {
            InboxPanelContentView(runtime: runtime)
        } else {
            Text(String(localized: "inbox.unavailable", defaultValue: "Inbox is unavailable in this window."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("InboxPanelUnavailable")
        }
    }
}

private struct InboxPanelContentView: View {
    let runtime: InboxRuntime
    @State private var draftBody = ""

    private let filters: [InboxListFilter] = [.actionable, .unread, .all]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { runtime.start() }
        .onChange(of: runtime.currentDraft?.draftID) { _, _ in syncDraftBody() }
        .onChange(of: runtime.currentDraft?.body) { _, _ in syncDraftBody() }
        .accessibilityIdentifier("InboxPanel")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { runtime.filter }, set: { runtime.setFilter($0) })) {
                    ForEach(filters) { filter in
                        Text(InboxLocalized.filterLabel(filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("InboxFilterPicker")

                Button {
                    runtime.sync(source: runtime.selectedSource)
                } label: {
                    Image(systemName: runtime.isSyncing ? "arrow.triangle.2.circlepath.circle" : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "inbox.sync.tooltip", defaultValue: "Sync selected source"))
                .accessibilityLabel(String(localized: "inbox.sync.accessibilityLabel", defaultValue: "Sync Inbox"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(runtime.sourceChips) { chip in
                        InboxSourceChipView(
                            chip: chip,
                            label: InboxLocalized.sourceLabel(chip.source),
                            statusLabel: chip.status.map(InboxLocalized.statusLabel),
                            action: { runtime.setSource(chip.source) }
                        )
                    }
                }
                .padding(.horizontal, 1)
            }
            .accessibilityIdentifier("InboxSourceChips")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = runtime.loadState {
                Text(message)
                    .cmuxFont(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
                itemList
                    .frame(minHeight: 160, idealHeight: 260)
                Divider()
                InboxThreadDetailView(
                    thread: runtime.selectedThread,
                    recentItems: runtime.recentItems,
                    draft: runtime.currentDraft,
                    sendState: runtime.sendState(),
                    draftBody: $draftBody,
                    onDraft: { runtime.draftReply(threadID: $0, instruction: nil) },
                    onDraftBodyChanged: { runtime.updateDraftBody($0) },
                    onSend: { runtime.sendApprovedDraft() },
                    onOpenOriginal: { runtime.openOriginal() },
                    onMarkRead: { runtime.markRead(threadID: $0) }
                )
                .frame(minHeight: 220)
            }

            if runtime.selectedSource == .agent {
                Divider()
                FeedPanelView()
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("InboxAgentFeedCompatibility")
            }
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if runtime.rows.isEmpty {
                    emptyState
                } else {
                    ForEach(runtime.rows) { row in
                        InboxRowView(
                            row: row,
                            sourceLabel: InboxLocalized.sourceLabel(row.source),
                            ageLabel: Self.ageFormatter.localizedString(for: row.timestamp, relativeTo: Date()),
                            isSelected: row.threadID == runtime.selectedThread?.threadID,
                            actions: InboxRowActions(
                                select: { runtime.selectThread(row.threadID) },
                                markRead: { runtime.markRead(itemID: row.itemID) },
                                openOriginal: { runtime.openOriginal(row: row) }
                            )
                        )
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("InboxItemList")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(String(localized: "inbox.empty.title", defaultValue: "Inbox is clear"))
                .cmuxFont(size: 13, weight: .medium)
            Text(String(localized: "inbox.empty.subtitle", defaultValue: "New agent and integration activity appears here."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func syncDraftBody() {
        let body = runtime.currentDraft?.body ?? ""
        if draftBody != body {
            draftBody = body
        }
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

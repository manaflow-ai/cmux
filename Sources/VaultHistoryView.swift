import CmuxFoundation
import SwiftUI

/// The Vault History tab: a unified timeline of workspace/window lifecycle
/// events and agent sessions, grouped by the user's chosen dimension
/// (date buckets by default, "Last 24 hours" first).
struct VaultHistoryView: View {
    @ObservedObject var sessionStore: SessionIndexStore
    /// Injected so previews/tests can point at an isolated log.
    let log: VaultHistoryEventLog
    @State private var model: VaultHistoryTimelineModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                VaultHistoryContentView(sessionStore: sessionStore, log: log, model: model)
            } else {
                Color.clear
                    .onAppear {
                        if model == nil {
                            model = VaultHistoryTimelineModel(log: log)
                        }
                    }
            }
        }
    }
}

private struct VaultHistoryContentView: View {
    @ObservedObject var sessionStore: SessionIndexStore
    let log: VaultHistoryEventLog
    let model: VaultHistoryTimelineModel

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if !model.didLoad {
                loadingView
            } else if model.groups.isEmpty {
                emptyView
            } else {
                timelineList
            }
        }
        .onAppear {
            if sessionStore.entries.isEmpty && !sessionStore.isLoading {
                sessionStore.reload()
            }
            model.refresh(sessionEntries: sessionStore.entries)
        }
        .onChange(of: sessionStore.entries) { _, entries in
            model.refresh(sessionEntries: entries)
        }
        .onChange(of: log.revision) { _, _ in
            model.refresh(sessionEntries: sessionStore.entries)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(VaultHistoryGroupKey.allCases) { key in
                    Button {
                        model.groupKey = key
                    } label: {
                        if model.groupKey == key {
                            Label(key.label, systemImage: "checkmark")
                        } else {
                            Text(key.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.groupKey.symbolName)
                        .cmuxFont(
                            size: RightSidebarChromeControlStyle.secondaryIconSize,
                            weight: RightSidebarChromeControlStyle.iconWeight
                        )
                    Text(model.groupKey.label)
                        .cmuxFont(
                            size: RightSidebarChromeControlStyle.labelSize,
                            weight: RightSidebarChromeControlStyle.labelWeight
                        )
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "vaultHistory.groupPicker.tooltip", defaultValue: "Group history by"))
            .accessibilityIdentifier("VaultHistoryGroupPicker")
            .titlebarInteractiveControl()

            Spacer(minLength: 4)

            Button {
                sessionStore.reload()
                model.refresh(sessionEntries: sessionStore.entries)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .cmuxFont(size: 10, weight: .medium)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "vaultHistory.reload.tooltip", defaultValue: "Reload History"))
            .disabled(model.isLoading || sessionStore.isLoading)
            .titlebarInteractiveControl()
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "vaultHistory.loading", defaultValue: "Loading history…"))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Text(String(localized: "vaultHistory.empty.title", defaultValue: "No history yet"))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
            Text(String(
                localized: "vaultHistory.empty.subtitle",
                defaultValue: "Workspace, window, and agent session activity will appear here."
            ))
            .cmuxFont(size: 11)
            .foregroundColor(.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timelineList: some View {
        // Snapshot value data before entering the lazy subtree: rows below
        // the LazyVStack boundary receive plain values, never store refs.
        let groups = model.groups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            VaultHistoryEventRow(event: event)
                        }
                    } header: {
                        VaultHistoryGroupHeader(title: group.title, count: group.events.count)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct VaultHistoryGroupHeader: View, Equatable {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text("\(count)")
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct VaultHistoryEventRow: View, Equatable {
    let event: VaultHistoryEvent

    nonisolated static func == (lhs: VaultHistoryEventRow, rhs: VaultHistoryEventRow) -> Bool {
        lhs.event == rhs.event
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: event.kind.symbolName)
                .cmuxFont(size: 10, weight: .regular)
                .foregroundColor(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .cmuxFont(size: 11.5)
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                Text(subtitle)
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Self.relativeFormatter.localizedString(for: event.timestamp, relativeTo: Date()))
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.7))
                .help(Self.absoluteFormatter.string(from: event.timestamp))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var displayTitle: String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        switch event.kind {
        case .windowOpened, .windowClosed:
            return String(localized: "vaultHistory.window", defaultValue: "Window")
        default:
            return String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if event.kind == .sessionActivity,
           let raw = event.subject.agent,
           let agent = SessionAgent(rawValue: raw) {
            parts.append(agent.displayName)
        } else {
            parts.append(event.kind.label)
        }
        if event.kind == .workspaceRenamed, let previousTitle = event.previousTitle, !previousTitle.isEmpty {
            parts.append(String(
                format: String(localized: "vaultHistory.detail.renamedFrom", defaultValue: "was “%@”"),
                previousTitle
            ))
        }
        if let count = event.workspaceCount {
            parts.append(Self.workspaceCountLabel(count))
        }
        if let directory = event.subject.directory, !directory.isEmpty {
            // String-only path math: URL(fileURLWithPath:) would stat the path.
            let component = (directory as NSString).lastPathComponent
            if !component.isEmpty, component != "." {
                parts.append(component)
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func workspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "vaultHistory.workspaceCount.one", defaultValue: "1 workspace")
        }
        return String.localizedStringWithFormat(
            String(localized: "vaultHistory.workspaceCount.other", defaultValue: "%d workspaces"),
            count
        )
    }
}

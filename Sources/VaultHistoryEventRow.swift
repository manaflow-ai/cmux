import SwiftUI

enum VaultHistoryRowAction: Equatable {
    case resumeSession(SessionEntry)
    case reopenClosedItem(UUID)

    var label: String {
        switch self {
        case .resumeSession:
            return String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab")
        case .reopenClosedItem:
            return String(localized: "vaultHistory.action.reopen", defaultValue: "Reopen")
        }
    }

    var symbolName: String {
        switch self {
        case .resumeSession: return "play.fill"
        case .reopenClosedItem: return "arrow.uturn.backward"
        }
    }
}

struct VaultHistoryRowActions {
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?

    var canResume: Bool { onResume != nil }
    var canReopen: Bool { onReopenClosedItem != nil }

    func perform(_ action: VaultHistoryRowAction) {
        switch action {
        case .resumeSession(let entry):
            onResume?(entry)
        case .reopenClosedItem(let id):
            _ = onReopenClosedItem?(id)
        }
    }
}

/// Value-only History row with optional resume or reopen behavior.
struct VaultHistoryEventRow: View, Equatable {
    let event: VaultHistoryEvent
    let action: VaultHistoryRowAction?
    let actions: VaultHistoryRowActions
    @State private var isHovered = false

    nonisolated static func == (lhs: VaultHistoryEventRow, rhs: VaultHistoryEventRow) -> Bool {
        lhs.event == rhs.event && lhs.action == rhs.action
    }

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
            Text(event.timestamp, style: .relative)
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.7))
                .help(event.timestamp.formatted(date: .abbreviated, time: .shortened))
            if let action {
                Button {
                    actions.perform(action)
                } label: {
                    Image(systemName: action.symbolName)
                        .cmuxFont(size: 9, weight: .medium)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(action.label)
                .help(action.label)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if let action {
                actions.perform(action)
            }
        }
        .contextMenu {
            if let action {
                Button {
                    actions.perform(action)
                } label: {
                    Label(action.label, systemImage: action.symbolName)
                }
            }
        }
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
        if event.kind == .sessionActivity {
            if let displayName = event.subject.agentDisplayName, !displayName.isEmpty {
                parts.append(displayName)
            } else if let raw = event.subject.agent,
                      let agent = SessionAgent(rawValue: raw) {
                parts.append(agent.displayName)
            } else {
                parts.append(event.kind.label)
            }
        } else {
            parts.append(event.kind.label)
        }
        if event.kind == .workspaceRenamed,
           let previousTitle = event.previousTitle,
           !previousTitle.isEmpty {
            parts.append(String(
                format: String(localized: "vaultHistory.detail.renamedFrom", defaultValue: "was “%@”"),
                previousTitle
            ))
        }
        if let count = event.workspaceCount {
            parts.append(Self.workspaceCountLabel(count))
        }
        if let directory = event.subject.directory, !directory.isEmpty {
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

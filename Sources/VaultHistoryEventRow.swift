import CmuxFoundation
import CmuxVaultHistory
import Foundation
import SwiftUI

/// Value-only row rendered below the History lazy-list boundary.
struct VaultHistoryEventRow: View, Equatable {
    let event: VaultHistoryEvent
    @State private var isHovered = false

    nonisolated static func == (lhs: VaultHistoryEventRow, rhs: VaultHistoryEventRow) -> Bool {
        lhs.event == rhs.event
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    eventIcon
                }
                .frame(width: 20, height: 20)

                Text(displayTitle)
                    .cmuxFont(size: 13)
                    .foregroundColor(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(min(event.timestamp, Date()), format: .relative(
                    presentation: .numeric,
                    unitsStyle: .abbreviated
                ))
                    .cmuxFont(size: 12, monospacedDigit: true)
                    .foregroundColor(.secondary.opacity(0.65))
                    // Reserve the time's intrinsic width so long titles
                    // truncate without wrapping the timestamp vertically.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(event.timestamp.formatted(date: .numeric, time: .shortened))
            }

            Text(subtitle)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 26)
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .help(displayTitle)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var eventIcon: some View {
        if event.kind == .sessionActivity,
           let rawValue = event.subject.agent,
           let agent = SessionAgent(rawValue: rawValue) {
            SessionIndexAgentIconImage(agent: agent, size: 12)
        } else {
            CmuxSystemSymbolImage(
                magnified: event.kind.symbolName,
                pointSize: 11,
                weight: .regular
            )
            .foregroundColor(iconColor)
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .workspaceCreated, .windowOpened:
            return .green
        case .workspaceRenamed:
            return .orange
        case .sessionActivity:
            return .accentColor
        case .workspaceClosed, .windowClosed:
            return .secondary
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .padding(.horizontal, 4)
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
           let rawValue = event.subject.agent,
           let agent = SessionAgent(rawValue: rawValue) {
            parts.append(agent.displayName)
        } else {
            parts.append(event.kind.label)
        }
        if event.kind == .workspaceRenamed,
           let previousTitle = event.previousTitle,
           !previousTitle.isEmpty {
            parts.append(String.localizedStringWithFormat(
                String(
                    localized: "vaultHistory.detail.renamedFrom",
                    defaultValue: "was “%@”"
                ),
                previousTitle
            ))
        }
        if let count = event.workspaceCount {
            parts.append(Self.workspaceCountLabel(count))
        }
        if let directory = event.subject.directory, !directory.isEmpty {
            // String-only path math avoids filesystem access in a lazy row body.
            let component = (directory as NSString).lastPathComponent
            if !component.isEmpty, component != "." {
                parts.append(component)
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func workspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(
                localized: "vaultHistory.workspaceCount.one",
                defaultValue: "1 workspace"
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "vaultHistory.workspaceCount.other",
                defaultValue: "%d workspaces"
            ),
            count
        )
    }
}

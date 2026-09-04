import CmuxFoundation
import CmuxVaultHistory
import Foundation
import SwiftUI

/// Value-only row rendered below the History lazy-list boundary.
struct VaultHistoryEventRow: View, Equatable {
    let event: VaultHistoryEvent

    nonisolated static func == (lhs: VaultHistoryEventRow, rhs: VaultHistoryEventRow) -> Bool {
        lhs.event == rhs.event
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
            Text(event.timestamp, format: .relative(
                presentation: .numeric,
                unitsStyle: .abbreviated
            ))
            .cmuxFont(size: 10)
            .foregroundColor(.secondary.opacity(0.7))
            .help(event.timestamp.formatted(date: .numeric, time: .shortened))
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
            String(localized: "vaultHistory.window", defaultValue: "Window")
        default:
            String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
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

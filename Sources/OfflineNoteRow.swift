import Foundation
import SwiftUI

/// A single note row. Holds only an immutable snapshot + action closures.
struct OfflineNoteRow: View {
    let note: OfflineNote
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusBadge
                Spacer(minLength: 0)
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Text(note.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if note.status == .failed, let error = note.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if note.status == .failed {
                    Button(action: onRetry) {
                        Label(
                            String(localized: "offlineNotes.row.retry", defaultValue: "Retry"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                Button(action: onDelete) {
                    Label(
                        String(localized: "offlineNotes.row.delete", defaultValue: "Delete"),
                        systemImage: "trash"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBadge: some View {
        Label(note.status.displayLabel, systemImage: note.status.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(note.status.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(note.status.tint.opacity(0.12), in: Capsule())
    }

    private var relativeTime: String {
        Self.relativeTimeFormatter.localizedString(for: note.createdAt, relativeTo: Date())
    }

    /// Shared across row renders so a flush (which republishes every row) does
    /// not reallocate a formatter per render.
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private extension OfflineNoteStatus {
    var displayLabel: String {
        switch self {
        case .pending:
            return String(localized: "offlineNotes.badge.pending", defaultValue: "Pending")
        case .sending:
            return String(localized: "offlineNotes.badge.sending", defaultValue: "Staging")
        case .staged:
            return String(localized: "offlineNotes.badge.staged", defaultValue: "Staged")
        case .sent:
            return String(localized: "offlineNotes.badge.sent", defaultValue: "Sent")
        case .failed:
            return String(localized: "offlineNotes.badge.failed", defaultValue: "Failed")
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock"
        case .sending: return "text.bubble"
        case .staged: return "text.bubble"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .sending: return .blue
        case .staged: return .purple
        case .sent: return .green
        case .failed: return .red
        }
    }
}

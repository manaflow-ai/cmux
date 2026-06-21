#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

extension TerminalComposerView {
    var queuedNotes: [OfflineAgentNote] {
        store.offlineAgentNotes
    }

    var queuedNoteCounts: (pending: Int, sending: Int, sent: Int, failed: Int) {
        (
            pending: queuedNotes.filter { $0.status == .pending }.count,
            sending: queuedNotes.filter { $0.status == .sending }.count,
            sent: queuedNotes.filter { $0.status == .sent }.count,
            failed: queuedNotes.filter { $0.status == .failed }.count
        )
    }

    var latestQueuedNoteSnippet: String? {
        queuedNotes
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var offlineNoteStatusRow: some View {
        let counts = queuedNoteCounts
        let title: String
        let systemImage: String
        let tint: Color
        if counts.failed > 0 {
            title = String(
                format: L10n.string("mobile.composer.offlineNotes.failed", defaultValue: "%d failed"),
                counts.failed
            )
            systemImage = "exclamationmark.triangle.fill"
            tint = .orange
        } else if counts.sending > 0 {
            title = L10n.string("mobile.composer.offlineNotes.sending", defaultValue: "Sending note")
            systemImage = "paperplane.fill"
            tint = .accentColor
        } else if counts.pending > 0 {
            title = String(
                format: L10n.string("mobile.composer.offlineNotes.queued", defaultValue: "%d queued"),
                counts.pending
            )
            systemImage = "tray.and.arrow.down.fill"
            tint = .accentColor
        } else {
            title = L10n.string("mobile.composer.offlineNotes.sent", defaultValue: "Note sent")
            systemImage = "checkmark.circle.fill"
            tint = .green
        }

        return HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TerminalPalette.foreground)
                    .lineLimit(1)
                Text(offlineNoteSubtitle(counts: counts))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(TerminalPalette.foreground.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if counts.failed > 0 || counts.pending > 0 {
                Button {
                    Task { @MainActor in
                        await store.retryOfflineAgentNotes()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TerminalPalette.foreground.opacity(0.72))
                .accessibilityLabel(L10n.string("mobile.composer.offlineNotes.retry", defaultValue: "Retry queued notes"))
            }

            if counts.pending == 0, counts.sending == 0, counts.failed == 0 {
                Button {
                    Task { @MainActor in
                        await store.clearSentOfflineAgentNotes()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TerminalPalette.foreground.opacity(0.62))
                .accessibilityLabel(L10n.string("mobile.composer.offlineNotes.dismiss", defaultValue: "Dismiss sent notes"))
            }
        }
        .padding(.leading, controlHeight + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .mobileGlassField(cornerRadius: 14)
        .accessibilityIdentifier("MobileComposerOfflineNotes")
    }

    func offlineNoteSubtitle(counts: (pending: Int, sending: Int, sent: Int, failed: Int)) -> String {
        if counts.pending > 0 {
            return L10n.string("mobile.composer.offlineNotes.waiting", defaultValue: "Will send when the Mac reconnects")
        }
        if let latestQueuedNoteSnippet, !latestQueuedNoteSnippet.isEmpty {
            return latestQueuedNoteSnippet
        }
        return L10n.string("mobile.composer.offlineNotes.empty", defaultValue: "No note text")
    }
}
#endif

import AppKit
import SwiftUI

/// Right-sidebar "Notes" view: capture notes (typically while offline) and
/// watch them turn into agent tasks once connectivity returns.
///
/// Rows receive immutable ``OfflineNote`` snapshots plus closure action bundles
/// only — no view below the list holds the store (snapshot-boundary rule).
struct OfflineNotesPanelView: View {
    /// The workspace a captured note is bound to, so it is later delivered back
    /// to this workspace's agent rather than whatever is active at flush time.
    let workspaceID: UUID?

    /// The app-wide `@Observable` store; SwiftUI tracks the properties read in
    /// `body`. Held as a plain reference (not owned) since it outlives the view.
    private let store = OfflineNotesStore.shared
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            composer
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Opening Notes means a window is up, so retry any notes left pending
            // by an earlier flush that ran before windows were ready. No-ops when
            // offline or when the queue has nothing pending.
            await store.flush()
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            Label {
                Text(connectivityLabel)
                    .font(.system(size: 11, weight: .medium))
            } icon: {
                Image(systemName: store.isOnline ? "wifi" : "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(store.isOnline ? Color.secondary : Color.orange)

            Spacer(minLength: 0)

            if store.failedCount > 0 {
                pillButton(
                    title: String(localized: "offlineNotes.action.retryAll", defaultValue: "Retry"),
                    symbol: "arrow.clockwise"
                ) {
                    store.retryAllFailed()
                }
            }
            if store.pendingCount > 0 {
                pillButton(
                    title: String(localized: "offlineNotes.action.sendAll", defaultValue: "Send"),
                    symbol: "paperplane",
                    disabled: !store.isOnline
                ) {
                    Task { await store.flush() }
                }
            }
            if store.sentCount > 0 {
                pillButton(
                    title: String(localized: "offlineNotes.action.clearSent", defaultValue: "Clear sent"),
                    symbol: "checkmark.circle"
                ) {
                    store.clearSent()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var connectivityLabel: String {
        store.isOnline
            ? String(localized: "offlineNotes.status.online", defaultValue: "Online")
            : String(localized: "offlineNotes.status.offline", defaultValue: "Offline — notes will queue")
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                String(localized: "offlineNotes.composer.placeholder", defaultValue: "Capture a note…"),
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...5)
            .onSubmit(submitDraft)
            .accessibilityIdentifier("offlineNotesComposer")

            Button(action: submitDraft) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(String(localized: "offlineNotes.composer.add", defaultValue: "Add note"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submitDraft() {
        guard store.addNote(draft, workspaceID: workspaceID) != nil else { return }
        draft = ""
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.notes.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Newest first.
                    ForEach(store.notes.reversed()) { note in
                        OfflineNoteRow(
                            note: note,
                            onRetry: { store.retry(id: note.id) },
                            onDelete: { store.deleteNote(id: note.id) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(localized: "offlineNotes.empty.title", defaultValue: "No notes yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "offlineNotes.empty.subtitle",
                defaultValue: "Jot things down while offline. They'll be sent to an agent once you're back online."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func pillButton(
        title: String,
        symbol: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
        .disabled(disabled)
    }
}

private extension OfflineNoteStatus {
    var displayLabel: String {
        switch self {
        case .pending:
            return String(localized: "offlineNotes.badge.pending", defaultValue: "Pending")
        case .sending:
            return String(localized: "offlineNotes.badge.sending", defaultValue: "Sending")
        case .sent:
            return String(localized: "offlineNotes.badge.sent", defaultValue: "Sent")
        case .failed:
            return String(localized: "offlineNotes.badge.failed", defaultValue: "Failed")
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock"
        case .sending: return "paperplane"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .sending: return .blue
        case .sent: return .green
        case .failed: return .red
        }
    }
}

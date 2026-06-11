#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// "View as Text": presents the visible terminal's content (recent scrollback
/// plus the visible screen) as plain, natively selectable text so long-press
/// selection, Select All, and Copy just work. The Ghostty render surface has
/// no iOS text-selection affordance, which made copy-paste from the mobile
/// terminal effectively impossible; this sheet is the copy path.
///
/// Content is read locally from the phone's own libghostty surface (no Mac
/// RPC, works offline) via `GhosttySurfaceView.copyableTerminalText()` and
/// capped to `TerminalTextSnapshot.defaultLineBudget` lines, with a banner
/// when older lines were dropped.
struct TerminalTextSheetView: View {
    /// The shell-level surface/terminal id whose text the sheet shows — the
    /// terminal selected in the workspace that opened it. Nil when the
    /// workspace has no terminal; the sheet then shows its empty state.
    let surfaceID: String?

    @Environment(\.dismiss) private var dismiss

    /// Loaded once per presentation in `.task`; nil while the off-main surface
    /// read is in flight.
    @State private var snapshot: TerminalTextSnapshot?
    @State private var isLoading = true
    /// Flips the Copy All label to a checkmark after a copy. Reset is the next
    /// presentation (fresh `@State`), so no timer is needed.
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.string("mobile.textSheet.title", defaultValue: "Terminal Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.textSheet.done", defaultValue: "Done")) {
                            dismiss()
                        }
                        .accessibilityIdentifier("MobileTerminalTextSheetDone")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        copyAllButton
                    }
                }
        }
        .task { await loadSnapshot() }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, !snapshot.text.isEmpty {
            VStack(spacing: 0) {
                if snapshot.isTruncated {
                    truncationBanner(lineBudget: snapshot.lineBudget)
                }
                SelectableTextView(text: snapshot.text)
            }
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L10n.string(
                "mobile.textSheet.empty",
                defaultValue: "No terminal text available"
            ))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("MobileTerminalTextSheetEmpty")
        }
    }

    private var copyAllButton: some View {
        Button(action: copyAll) {
            if didCopy {
                Label(
                    L10n.string("mobile.textSheet.copied", defaultValue: "Copied"),
                    systemImage: "checkmark"
                )
            } else {
                Text(L10n.string("mobile.textSheet.copyAll", defaultValue: "Copy All"))
            }
        }
        .disabled(snapshot?.text.isEmpty ?? true)
        .accessibilityIdentifier("MobileTerminalTextCopyAllButton")
    }

    private func truncationBanner(lineBudget: Int) -> some View {
        Text(String(
            format: L10n.string(
                "mobile.textSheet.truncated",
                defaultValue: "Showing the last %d lines."
            ),
            lineBudget
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("MobileTerminalTextSheetTruncationBanner")
    }

    private func loadSnapshot() async {
        guard let surfaceID else {
            isLoading = false
            return
        }
        let fullText = await GhosttySurfaceView.copyableTerminalText(surfaceID: surfaceID)
        // Cap off the main actor: the capture is bounded by the iOS surface's
        // scrollback-limit (~2MB, see applyiOSDefaults), but splitting and
        // rejoining even that much text is O(content) string work that would
        // jank the UI if run on main.
        let capped: TerminalTextSnapshot? = await Task.detached(priority: .userInitiated) {
            fullText.map { TerminalTextSnapshot.capped(fullText: $0) }
        }.value
        snapshot = capped
        isLoading = false
    }

    private func copyAll() {
        guard let text = snapshot?.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didCopy = true
    }
}

/// A read-only `UITextView` wrapper: the native iOS text view is what gives
/// the sheet real long-press selection, drag handles, Select All, and Copy.
/// SwiftUI's `Text` + `.textSelection(.enabled)` only offers whole-blob copy,
/// not range selection, which defeats the point of the sheet.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        // Terminal output is data, not prose: keep iOS from restyling it.
        view.dataDetectorTypes = []
        view.text = text
        view.accessibilityIdentifier = "MobileTerminalTextSheetTextView"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Guarded so SwiftUI re-renders don't clobber an active selection.
        if uiView.text != text {
            uiView.text = text
        }
    }
}
#endif

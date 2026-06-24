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
    private static let captureTimeout: Duration = .seconds(3)

    /// The shell-level surface/terminal id whose text the sheet shows — the
    /// terminal selected in the workspace that opened it. Nil when the
    /// workspace has no terminal; the sheet then shows its empty state.
    let surfaceID: String?

    /// The capture started by `openTextSheetFromMenu` the instant the menu item
    /// was tapped, while the terminal surface was still fully window-attached.
    /// Preferred over re-resolving from the registry inside `.task`: by the time
    /// the sheet's `.task` runs the presenter's window/alpha may have dropped,
    /// and the registry pick is visibility-scoped, so a late resolve could miss
    /// the live surface and show the empty state. The sheet just awaits this.
    /// Nil falls back to a fresh resolve so the path still works if the capture
    /// was never armed.
    let capture: Task<String?, Never>?

    @Environment(\.dismiss) private var dismiss

    /// Loaded once per presentation in `.task`; nil while the off-main surface
    /// read is in flight.
    @State private var snapshot: TerminalTextSnapshot?
    @State private var isLoading = true
    @State private var errorMessage: String?
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
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileTerminalTextSheetError")
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
        errorMessage = nil
        // Prefer the capture armed at tap time (surface still fully on screen).
        // Only fall back to a fresh resolve when no capture was provided, which
        // re-resolves from the registry and can miss the live surface if the
        // sheet's presentation dropped the presenter's window/alpha.
        let captureTask: Task<String?, Never>
        if let existingCapture = capture {
            captureTask = existingCapture
        } else {
            guard let surfaceID else {
                isLoading = false
                return
            }
            captureTask = await GhosttySurfaceView.copyableTerminalTextCapture(surfaceID: surfaceID)
        }

        let outcome = await awaitCapture(captureTask)
        guard !Task.isCancelled else { return }
        let fullText: String?
        if outcome.timedOut {
            errorMessage = L10n.string(
                "mobile.textSheet.timeout",
                defaultValue: "Terminal text took too long to load. Close this sheet and try again."
            )
            isLoading = false
            return
        }
        fullText = outcome.text
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

    private func awaitCapture(_ capture: Task<String?, Never>) async -> (timedOut: Bool, text: String?) {
        let state = TerminalTextCaptureRaceState()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let waiter = Task.detached(priority: .userInitiated) {
                    let text = await capture.value
                    await state.finish(timedOut: false, text: text)
                }
                let timer = Task.detached(priority: .userInitiated) {
                    do {
                        try await ContinuousClock().sleep(for: Self.captureTimeout)
                    } catch {
                        return
                    }
                    capture.cancel()
                    await state.finish(timedOut: true, text: nil)
                }
                Task {
                    await state.install(continuation: continuation)
                    await state.setWaiter(waiter)
                    await state.setTimer(timer)
                }
            }
        }, onCancel: {
            capture.cancel()
            Task {
                await state.cancel()
            }
        })
    }

    private func copyAll() {
        guard let text = snapshot?.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didCopy = true
    }
}
#endif

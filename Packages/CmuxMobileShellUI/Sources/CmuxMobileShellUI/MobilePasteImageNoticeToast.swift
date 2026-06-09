import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Transient bottom toast that surfaces a failed image paste (most often an
/// image too large to fit the sync frame). Renders nothing while
/// ``CMUXMobileShellStore/pasteImageNotice`` is `nil`, fades in when a notice
/// appears, and auto-dismisses after a short, cancellable delay so it never
/// lingers or blocks the terminal.
///
/// This is deliberately separate from ``MobileConnectionRecoveryBanner``: an
/// oversized paste is not a connection failure, so it must not show the Retry /
/// reconnect affordances or imply the Mac is unreachable.
struct MobilePasteImageNoticeToast: View {
    @Bindable var store: CMUXMobileShellStore

    /// How long the toast stays up before auto-dismissing. A bounded, intended
    /// display duration (not a synchronization sleep), wired to the notice's
    /// lifecycle below so a new notice or a manual tap cancels the pending hide.
    private static let autoDismiss: Duration = .seconds(3)

    var body: some View {
        Group {
            if let notice = store.pasteImageNotice {
                toast(text: notice)
                    .task(id: store.pasteImageNoticeToken) {
                        // Concurrency carve-out: a bounded, cancellable auto-dismiss
                        // delay that is itself the intended behavior (a minimum
                        // display duration), not a poll/settle/race. `.task(id:)`
                        // cancels and restarts when the monotonic notice token
                        // changes (so a repeat paste with identical text still
                        // restarts the timer) and cancels on disappear, wiring the
                        // sleep's cancellation to the toast lifecycle.
                        try? await Task.sleep(for: Self.autoDismiss)
                        guard !Task.isCancelled else { return }
                        store.dismissPasteImageNotice()
                    }
            }
        }
        .animation(.default, value: store.pasteImageNotice)
    }

    private func toast(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.dismissPasteImageNotice() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("MobilePasteImageNoticeToast")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

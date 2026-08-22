#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    func chatWaitingSurfacePlaceholder() -> some View {
        waitingSurfacePlaceholder(
            title: L10n.string("mobile.chat.waiting", defaultValue: "Waiting for Chat"),
            detail: L10n.string(
                "mobile.chat.waitingDetail",
                defaultValue: "The conversation will appear when it is ready."
            ),
            symbol: "bubble.left.and.bubble.right",
            accessibilityIdentifier: "WorkspaceChatPlaceholder"
        )
    }

    @ViewBuilder
    func waitingSurfacePlaceholder(
        title: String,
        detail: String,
        symbol: String,
        accessibilityIdentifier: String
    ) -> some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 36))
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
#endif

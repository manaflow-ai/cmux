#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
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

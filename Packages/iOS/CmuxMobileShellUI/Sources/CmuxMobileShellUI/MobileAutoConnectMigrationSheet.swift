#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    /// The system caps an oversized height detent, turning the scroll view into
    /// the fallback only when the wrapped content exceeds the available screen.
    @State private var contentHeight: CGFloat = 1
    @State private var viewportHeight: CGFloat = 0

    private var usesScrollFallback: Bool {
        viewportHeight > 0 && contentHeight > viewportHeight + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MobileAutoConnectMigrationContent(
                    continueWithAutoConnect: continueWithAutoConnect,
                    openConnectionSettings: openConnectionSettings
                )
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    contentHeight = max(newHeight, 1)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                viewportHeight = newHeight
            }
            .accessibilityIdentifier(
                usesScrollFallback
                    ? "MobileAutoConnectMigrationScrollView"
                    : "MobileAutoConnectMigrationIntrinsicContainer"
            )
        }
        .presentationDetents([.height(contentHeight)])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileAutoConnectMigrationSheet")
    }
}

private struct MobileAutoConnectMigrationContent: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            MobileAutoConnectMigrationExplanation()
            MobileAutoConnectMigrationActions(
                continueWithAutoConnect: continueWithAutoConnect,
                openConnectionSettings: openConnectionSettings
            )
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .accessibilityIdentifier("MobileAutoConnectMigrationContent")
    }
}
#endif

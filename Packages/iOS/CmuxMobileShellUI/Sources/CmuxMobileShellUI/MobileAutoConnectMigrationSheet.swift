#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void
    let showsLayoutProbe: Bool

    /// The requested detent follows the intrinsic content while the UIKit
    /// reader feeds the system's actual visible cap back into the ScrollView.
    @State private var contentHeight: CGFloat = 1
    @State private var availableViewportHeight: CGFloat?

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
            .frame(maxHeight: availableViewportHeight)
            #if DEBUG
            .overlay {
                if showsLayoutProbe {
                    MobileAutoConnectMigrationViewportProbe()
                }
            }
            #endif
        }
        .background {
            MobileAutoConnectMigrationViewportReader { newHeight in
                availableViewportHeight = newHeight
            }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }
}

#if DEBUG
/// A UI-test-only leaf that inherits the real scroll viewport's rendered frame.
private struct MobileAutoConnectMigrationViewportProbe: View {
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("MobileAutoConnectMigrationViewportProbe")
    }
}
#endif

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
    }
}
#endif

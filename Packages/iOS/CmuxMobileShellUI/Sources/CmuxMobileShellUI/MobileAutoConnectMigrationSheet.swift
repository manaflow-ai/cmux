#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void
    let showsLayoutProbe: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ViewThatFits(in: .vertical) {
            content

            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(idealWidth: 608, maxWidth: 608)
        #if DEBUG
        .overlay {
            if showsLayoutProbe {
                MobileAutoConnectMigrationViewportProbe()
            }
        }
        #endif
        .presentationSizing(.fitted)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        MobileAutoConnectMigrationContent(
            layout: verticalSizeClass == .compact ? .compact : .regular,
            continueWithAutoConnect: continueWithAutoConnect,
            openConnectionSettings: openConnectionSettings
        )
        .fixedSize(horizontal: false, vertical: true)
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
    let layout: MobileAutoConnectMigrationLayout
    let continueWithAutoConnect: () -> Void
    let openConnectionSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            MobileAutoConnectMigrationExplanation(layout: layout)
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

enum MobileAutoConnectMigrationLayout {
    case regular
    case compact

    var contentSpacing: CGFloat {
        switch self {
        case .regular:
            28
        case .compact:
            16
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Explains the BETA-to-Auto-Connect migration and exposes its two outcomes.
struct MobileAutoConnectMigrationSheet: View {
    let useAutoConnect: () -> Void
    let setUpTailscale: () -> Void
    let showsLayoutProbe: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 1

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
        .modifier(MobileAutoConnectMigrationPresentationSizing(
            contentHeight: contentHeight,
            usesPageSizing: dynamicTypeSize.isAccessibilitySize
        ))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        MobileAutoConnectMigrationContent(
            layout: verticalSizeClass == .compact ? .compact : .regular,
            useAutoConnect: useAutoConnect,
            setUpTailscale: setUpTailscale
        )
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            guard newHeight.isFinite, newHeight > 0 else { return }
            contentHeight = newHeight
        }
    }
}

private struct MobileAutoConnectMigrationPresentationSizing: ViewModifier {
    let contentHeight: CGFloat
    let usesPageSizing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesPageSizing {
            content
                .presentationSizing(.page)
                .presentationDetents([.large])
        } else {
            content
                .presentationSizing(.fitted)
                .presentationDetents([.height(contentHeight)])
        }
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
    let useAutoConnect: () -> Void
    let setUpTailscale: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            MobileAutoConnectMigrationExplanation(layout: layout)
            MobileAutoConnectMigrationActions(
                useAutoConnect: useAutoConnect,
                setUpTailscale: setUpTailscale
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

import CmuxMobileSupport
import SwiftUI

struct WorkspaceTitleMenu<Label: View, MenuContent: View>: View {
    var isEnabled = true
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        MobileToolbarPriorityHost(role: .compressibleTitle) {
            if isEnabled {
                Menu {
                    menuContent()
                } label: {
                    fittedLabel
                }
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
            } else {
                Button {} label: {
                    fittedLabel
                }
                .allowsHitTesting(false)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityIdentifier("MobileWorkspaceTitleMenu")
            }
        }
    }

    private var fittedLabel: some View {
        label()
            .layoutPriority(MobileToolbarItemLayoutRole.compressibleTitle.swiftUILayoutPriority)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
            .clipped()
    }
}

enum MobileToolbarItemLayoutRole {
    case compressibleTitle
    case fixedTrailingControls

    var swiftUILayoutPriority: Double {
        switch self {
        case .compressibleTitle:
            return -1
        case .fixedTrailingControls:
            return 1
        }
    }
}

struct MobileToolbarPriorityHost<Content: View>: View {
    let role: MobileToolbarItemLayoutRole
    let content: Content

    init(role: MobileToolbarItemLayoutRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        content
            .layoutPriority(role.swiftUILayoutPriority)
    }
}

struct MobileWorkspacePriorityToolbar<Back: View, Title: View, Trailing: View>: View {
    @ViewBuilder let back: () -> Back
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            back()
                .layoutPriority(MobileToolbarItemLayoutRole.fixedTrailingControls.swiftUILayoutPriority)
                .fixedSize()
                .mobileGlassCompactToolbarControl()

            title()
                .layoutPriority(MobileToolbarItemLayoutRole.compressibleTitle.swiftUILayoutPriority)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .mobileGlassCompactToolbarControl()
                .clipped()

            trailing()
                .layoutPriority(MobileToolbarItemLayoutRole.fixedTrailingControls.swiftUILayoutPriority)
                .fixedSize()
                .mobileGlassCompactToolbarControl()
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .center)
    }
}

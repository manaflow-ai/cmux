import CmuxMobileSupport
import SwiftUI

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

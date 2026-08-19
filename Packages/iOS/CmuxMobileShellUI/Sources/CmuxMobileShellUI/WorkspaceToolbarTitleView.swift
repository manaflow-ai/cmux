import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleView: View {
    let title: String
    let subtitle: String?
    let foregroundColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(foregroundColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            MobileCompactToolbarTitleStack(
                title: title,
                subtitle: subtitleLine,
                foregroundColor: foregroundColor
            )
        }
        .padding(.horizontal, MobileCompactToolbarTitleStack.horizontalContentPadding)
        .accessibilityElement(children: .combine)
    }

    private var subtitleLine: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }
}

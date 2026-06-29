import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleView: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            MobileCompactToolbarTitleStack(title: title, subtitle: subtitleLine)
        }
        .padding(.horizontal, MobileCompactToolbarTitleMetrics.horizontalContentPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitleLine: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    private var accessibilityLabel: String {
        guard let subtitleLine else { return title }
        return "\(title), \(subtitleLine)"
    }
}

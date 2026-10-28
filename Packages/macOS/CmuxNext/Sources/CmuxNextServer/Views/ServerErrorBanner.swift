import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// A refused Add Server approve, above the card's footer.
struct ServerErrorBanner: View {
    let text: String
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Icon(.statusWarning, size: Metrics.smallIconSize).foregroundStyle(colors.critical)
            Text(text).font(Font(Typography.body)).foregroundStyle(colors.critical).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Metrics.space3)
        .background(RoundedRectangle(cornerRadius: ServerMetrics.fieldRadius, style: .continuous)
            .fill(colors.critical.opacity(ServerMetrics.bannerFillOpacity)))
    }
}

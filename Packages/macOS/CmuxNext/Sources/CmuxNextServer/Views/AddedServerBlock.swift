import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Add Server card after Approve went through.
struct AddedServerBlock: View {
    let name: String
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: Metrics.space2) {
            Icon(.statusSuccess, size: ServerMetrics.successIconSize).foregroundStyle(colors.ok)
            Text(ServerStrings.added(name)).font(Font(Typography.header)).foregroundStyle(colors.primary)
            Text(ServerStrings.addedDetail).font(Font(Typography.body)).foregroundStyle(colors.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.space3)
    }
}

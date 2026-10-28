import CmuxNextDesign
import SwiftUI

/// The line under the Add Server code field: what to type, the lookup's spinner, or why the code
/// was refused (with what to do next).
struct CodeStatusLine: View {
    let step: AddServerStep
    @Environment(\.serverColors) private var colors

    var body: some View {
        switch step {
        case .lookingUp:
            HStack(spacing: Metrics.space2) {
                ThemedSpinner(size: ServerMetrics.spinnerSize)
                Text(ServerStrings.lookingUp).font(Font(Typography.body)).foregroundStyle(colors.secondary)
            }
        case let .codeRefused(reject):
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(reject).font(Font(Typography.body)).foregroundStyle(colors.critical)
                Text(ServerStrings.codeExpiryHint).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .enterCode:
            Text(ServerStrings.codeHint).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
        case .review, .approving, .approveFailed, .added:
            EmptyView()
        }
    }
}

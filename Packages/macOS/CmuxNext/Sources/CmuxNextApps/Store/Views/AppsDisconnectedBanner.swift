import CmuxNextDesign
import SwiftUI

/// Why nothing can change: the supervisor is unreachable. Every control
/// below is disabled; nothing queues.
struct AppsDisconnectedBanner: View {
    let reason: AppsUnavailableReason
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: "bolt.horizontal").font(.system(size: 11))
            Text(AppsStrings.unavailable(reason)).font(Font(Typography.bodyEmphasized))
            Text(AppsStrings.unavailableHelp).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            Spacer()
        }
        .foregroundStyle(colors.secondary)
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space2)
        .background(colors.hover)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appStore.disconnected")
    }
}

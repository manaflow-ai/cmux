import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the cmux Pro pitch (one title line + one price/value subtitle)
/// with a trailing button that asks the host to open the pricing page in
/// the default browser via ``AccountFlow/openProUpgrade()``. Stateless:
/// the app does not track plan state yet, so the row renders for every
/// user.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    init(flow: AccountFlow?) {
        self.flow = flow
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.account.pro.title", defaultValue: "cmux Pro"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(String(
                    localized: "settings.account.pro.subtitle",
                    defaultValue: "Cloud dev boxes, the iOS app, and cmux AI. $30/month, or $240/year."
                ))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                flow?.openProUpgrade()
            } label: {
                Text(String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…"))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

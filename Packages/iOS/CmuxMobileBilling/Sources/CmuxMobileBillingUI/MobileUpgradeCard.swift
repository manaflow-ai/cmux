#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// An upgrade call to action for a Free account: a title, one sentence, and
/// a See Plans button. Used at the top of Settings and where Cloud machines
/// are listed. Shown only when ``BillingModel/canOfferUpgrade`` is true, so
/// web subscribers, team billing and builds that sell nothing never see it.
///
/// Place it as a list row; it records `ios_upgrade_entry_viewed` each time
/// it appears.
///
/// HIG: In-app purchase (a clear, unobtrusive way to see the offer).
public struct MobileUpgradeCard: View {
    private let entryPoint: BillingEntryPoint
    private let title: String
    private let message: String
    private let open: () -> Void

    /// Creates the card.
    /// - Parameters:
    ///   - entryPoint: The entry point it stands for, for analytics.
    ///   - title: The title.
    ///   - message: One sentence under the title.
    ///   - open: Opens the paywall.
    public init(entryPoint: BillingEntryPoint, title: String, message: String, open: @escaping () -> Void) {
        self.entryPoint = entryPoint
        self.title = title
        self.message = message
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cloud.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 44, height: 44)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: open) {
                Text(L10n.string("mobile.billing.upgrade.seePlans", defaultValue: "See Plans"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(MobilePaywallPrimaryButtonStyle())
            .accessibilityIdentifier("BillingUpgradeCardButton.\(entryPoint.rawValue)")
        }
        .padding(.vertical, 6)
        .billingUpgradeEntryViewed(entryPoint)
        .accessibilityIdentifier("BillingUpgradeCard.\(entryPoint.rawValue)")
    }
}
#endif

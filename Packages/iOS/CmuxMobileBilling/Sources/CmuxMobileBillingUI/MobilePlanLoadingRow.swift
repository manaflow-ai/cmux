#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// The minimum height shared by a loading plan row and its resolved card.
/// Keeping this geometry stable means StoreKit prices and purchase controls can
/// arrive without inserting a new card into the first frame.
enum MobilePlanRowGeometry {
    static let minimumHeight: CGFloat = 220
}

/// A placeholder plan card shown while the account or StoreKit products load.
/// It reserves the same vertical space as a resolved offer, including its
/// purchase control, so the Plus card cannot shift the list when it arrives.
struct MobilePlanLoadingRow: View {
    let planID: BillingPlanID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 112, height: 22)
                Spacer(minLength: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 84, height: 22)
            }
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 176, height: 16)
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .padding(.vertical, 4)
        .frame(minHeight: MobilePlanRowGeometry.minimumHeight, alignment: .top)
        .accessibilityIdentifier("BillingLoadingPlan.\(planID.rawValue)")
    }
}
#endif

import CmuxFoundation
import SwiftUI

/// Visible marker that this process is running against the staging backend
/// (the ACTIVE environment, not a pending selection), so a switched device
/// is never mistaken for production. Shared by the account identity card and
/// the backend-environment recovery card.
@MainActor
struct StagingEnvironmentBadge: View {
    var body: some View {
        Text(String(localized: "settings.account.stagingBadge", defaultValue: "Staging"))
            .cmuxFont(size: 10, weight: .semibold)
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
    }
}

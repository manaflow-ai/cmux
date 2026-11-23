#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// ``MobilePlansView`` in its own navigation stack with a Done button, for
/// presenting as a sheet from screens that are not in a navigation stack.
///
/// HIG: Sheets (a Done button in the toolbar dismisses the sheet).
public struct MobilePlansSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let entryPoint: BillingEntryPoint

    /// Creates the sheet.
    /// - Parameter entryPoint: Where the sheet was opened from.
    public init(entryPoint: BillingEntryPoint) {
        self.entryPoint = entryPoint
    }

    public var body: some View {
        NavigationStack {
            MobilePlansView(entryPoint: entryPoint)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.billing.done", defaultValue: "Done")) { dismiss() }
                    }
                }
        }
    }
}
#endif

import SwiftUI

/// A popover's action buttons: `leading` (dismissive) on the left and `trailing` (primary) on
/// the right. When the buttons do not fit the popover width on one line, as with long
/// translations or three held-relaunch choices, the primary actions take their own line
/// above the others instead of spilling past the popover's edge.
struct UpdatePopoverButtonRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) { trailing }
                HStack(spacing: 8) { leading }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

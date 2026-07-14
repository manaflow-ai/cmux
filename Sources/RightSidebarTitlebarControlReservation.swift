import SwiftUI

/// Reserves the live native trailing-accessory width without invalidating the full sidebar tree.
struct RightSidebarTitlebarControlReservation: View {
    let layoutState: TitlebarTrailingControlsLayoutState

    var body: some View {
        Color.clear
            .frame(
                width: layoutState.reservationWidth,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .rightSidebarHeaderControlAlignment()
            .accessibilityHidden(true)
    }
}

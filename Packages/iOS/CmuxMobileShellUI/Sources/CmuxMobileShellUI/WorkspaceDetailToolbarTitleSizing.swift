#if os(iOS)
import CoreGraphics
import SwiftUI

/// Explicit title-width policy for the app-owned workspace detail bar.
///
/// The system navigation toolbar has no public remaining-width API on iOS 26.
/// The owned bar therefore uses stable size-class caps and reserves one fixed
/// amount for every additional visible control. The visible-item counts come
/// from the same lists that render the leading and trailing controls, so adding
/// a control cannot silently leave the title cap unchanged.
enum WorkspaceDetailToolbarTitleSizing {
    static let compactPortraitMaximum: CGFloat = 180
    static let compactLandscapeMaximum: CGFloat = 240
    static let regularPortraitMaximum: CGFloat = 280
    static let regularLandscapeMaximum: CGFloat = 360
    static let additionalTrailingItemReserve: CGFloat = 44
    static let additionalLeadingItemReserve: CGFloat = 44
    static let minimumTitleWidth: CGFloat = 96

    static func maximumTitleWidth(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        leadingItemCount: Int,
        trailingItemCount: Int
    ) -> CGFloat {
        let baseMaximum: CGFloat
        if horizontalSizeClass == .compact {
            baseMaximum = verticalSizeClass == .compact
                ? compactLandscapeMaximum
                : compactPortraitMaximum
        } else if verticalSizeClass == .compact {
            baseMaximum = regularLandscapeMaximum
        } else {
            baseMaximum = regularPortraitMaximum
        }

        let extraTrailingItems = CGFloat(max(trailingItemCount - 1, 0))
        let extraLeadingItems = CGFloat(max(leadingItemCount - 1, 0))
        return max(
            minimumTitleWidth,
            baseMaximum
                - extraTrailingItems * additionalTrailingItemReserve
                - extraLeadingItems * additionalLeadingItemReserve
        )
    }
}
#endif

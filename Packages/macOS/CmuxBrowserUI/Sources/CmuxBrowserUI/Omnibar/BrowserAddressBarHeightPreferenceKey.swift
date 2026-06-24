public import SwiftUI

/// Reduces the browser address-bar height preference to the maximum reported
/// height.
public struct BrowserAddressBarHeightPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

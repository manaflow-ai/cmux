public import SwiftUI

/// Reduces the browser address-bar width preference to the maximum reported
/// width.
public struct BrowserAddressBarWidthPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

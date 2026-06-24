public import SwiftUI

/// Coalesces omnibar pill-frame preference reports up the SwiftUI tree, keeping
/// the last non-zero frame.
public struct OmnibarPillFramePreferenceKey: PreferenceKey {
    public static var defaultValue: CGRect = .zero

    public static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

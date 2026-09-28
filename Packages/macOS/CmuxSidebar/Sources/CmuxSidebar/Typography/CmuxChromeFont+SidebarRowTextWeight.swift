public import AppKit
public import CmuxFoundation
public import SwiftUI

/// Chrome fonts for the sidebar's own weight vocabulary, so row code can ask
/// for "the selected title's font" without translating weights by hand.
extension CmuxChromeFont {
    public static func appKitFont(
        typeface: CmuxChromeTypeface,
        size: CGFloat,
        weight: SidebarRowTextWeight
    ) -> NSFont {
        appKitFont(typeface: typeface, size: size, weight: weight.appKitWeight)
    }

    public static func swiftUIFont(
        typeface: CmuxChromeTypeface,
        size: CGFloat,
        weight: SidebarRowTextWeight
    ) -> Font {
        swiftUIFont(typeface: typeface, size: size, weight: weight.appKitWeight)
    }
}

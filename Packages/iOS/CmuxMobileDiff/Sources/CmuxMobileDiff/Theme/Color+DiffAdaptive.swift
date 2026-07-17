public import SwiftUI

#if canImport(UIKit)
internal import UIKit
#elseif canImport(AppKit)
internal import AppKit
#endif

extension Color {
    /// Creates a dynamic color from explicit light and dark tokens.
    /// - Parameters:
    ///   - light: Light-appearance color.
    ///   - dark: Dark-appearance color.
    /// - Returns: A platform-adaptive color.
    public static func diffAdaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        light
        #endif
    }
}

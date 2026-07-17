public import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// Creates a dynamic color from explicit light and dark tokens.
    /// - Parameters:
    ///   - light: Color used in light appearance.
    ///   - dark: Color used in dark appearance.
    /// - Returns: A platform-adaptive SwiftUI color.
    public static func diffAdaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
        #else
        return dark
        #endif
    }
}

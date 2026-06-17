import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// A color that resolves per color scheme, for theme tokens whose dark
    /// and light appearances differ.
    ///
    /// - Parameters:
    ///   - light: The light-appearance color.
    ///   - dark: The dark-appearance color.
    /// - Returns: A dynamic color.
    public static func chatAdaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
        #elseif canImport(AppKit)
        return Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return isDark ? NSColor(dark) : NSColor(light)
                }
            )
        )
        #else
        return dark
        #endif
    }
}

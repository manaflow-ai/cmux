import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Framework-neutral dynamic color token for UIKit and AppKit consumers.
public struct ChatColor: Sendable, Equatable {
    private struct Components: Sendable, Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private let light: Components
    private let dark: Components

    public static let blue = ChatColor(red: 0, green: 0.478, blue: 1)

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        let components = Components(red: red, green: green, blue: blue, alpha: alpha)
        light = components
        dark = components
    }

    public init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static func adaptive(light: ChatColor, dark: ChatColor) -> ChatColor {
        ChatColor(light: light.light, dark: dark.dark)
    }

    private init(light: Components, dark: Components) {
        self.light = light
        self.dark = dark
    }

    #if canImport(UIKit)
    var uiColor: UIColor {
        UIColor { traits in
            Self.uiColor(
                traits.userInterfaceStyle == .dark ? dark : light
            )
        }
    }

    private static func uiColor(_ components: Components) -> UIColor {
        UIColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }
    #elseif canImport(AppKit)
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Self.nsColor(isDark ? dark : light)
        }
    }

    private static func nsColor(_ components: Components) -> NSColor {
        NSColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }
    #endif
}

import Foundation
import CoreGraphics

/// An sRGB color with 8-bit channels, as Ghostty config files spell colors.
public struct TerminalColor: Equatable, Hashable, Sendable {
    /// The red channel, 0 to 255.
    public var red: UInt8
    /// The green channel, 0 to 255.
    public var green: UInt8
    /// The blue channel, 0 to 255.
    public var blue: UInt8

    /// Creates a color from 8-bit sRGB channels.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The colorspace a source stored its floating-point components in.
    public enum ComponentSpace: Sendable {
        /// Already sRGB.
        case sRGB
        /// AppKit's calibrated (generic) RGB, used by older iTerm2 and Terminal profiles.
        case genericRGB
        /// Display P3.
        case displayP3
        /// Device RGB, treated as sRGB.
        case deviceRGB
    }

    /// Creates a color from floating-point components, converting to sRGB.
    ///
    /// - Parameters:
    ///   - red: Red component, 0 to 1.
    ///   - green: Green component, 0 to 1.
    ///   - blue: Blue component, 0 to 1.
    ///   - space: The colorspace the components are expressed in.
    public init(red: Double, green: Double, blue: Double, space: ComponentSpace = .sRGB) {
        var components = [red, green, blue]
        if let sourceName = space.cgColorSpaceName,
           let source = CGColorSpace(name: sourceName),
           let target = CGColorSpace(name: CGColorSpace.sRGB),
           let color = CGColor(colorSpace: source, components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1]),
           let converted = color.converted(to: target, intent: .defaultIntent, options: nil),
           let convertedComponents = converted.components,
           convertedComponents.count >= 3 {
            components = convertedComponents.prefix(3).map { Double($0) }
        }
        self.init(
            red: Self.channel(components[0]),
            green: Self.channel(components[1]),
            blue: Self.channel(components[2])
        )
    }

    /// Parses `#rrggbb`, `rrggbb`, `0xrrggbb`, `#rgb` or `#rrggbbaa` (alpha ignored).
    ///
    /// - Parameter hex: The color text; surrounding quotes and whitespace are ignored.
    /// - Returns: The color, or `nil` when the text is not a hex color.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        if text.hasPrefix("#") {
            text.removeFirst()
        } else if text.lowercased().hasPrefix("0x") {
            text.removeFirst(2)
        }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        if text.count == 8 {
            text = String(text.prefix(6))
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    /// The color as lowercase `#rrggbb`.
    public var hexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    private static func channel(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}

extension TerminalColor.ComponentSpace {
    fileprivate var cgColorSpaceName: CFString? {
        switch self {
        case .sRGB, .deviceRGB: return nil
        // `kCGColorSpaceGenericRGB` is not exported to Swift; its value is its name.
        case .genericRGB: return "kCGColorSpaceGenericRGB" as CFString
        case .displayP3: return CGColorSpace.displayP3
        }
    }
}

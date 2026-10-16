import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Encodes and bridges the platform colors emitted by Highlightr.
struct HighlightColorPacking: Sendable {
    private let hexDigits = Array("0123456789ABCDEF".utf8)

    func hexKey(fromPacked value: UInt32) -> String {
        var remaining = value
        var bytes = [UInt8](repeating: 48, count: 6)
        for index in stride(from: 5, through: 0, by: -1) {
            bytes[index] = hexDigits[Int(remaining & 0xF)]
            remaining >>= 4
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func packedRGBKey(red: CGFloat, green: CGFloat, blue: CGFloat) -> UInt32 {
        func component(_ value: CGFloat) -> UInt32 {
            // Clamp before multiplying/converting. A finite CGFloat can be
            // larger than Int.max / 255, and converting that product to Int
            // would trap even though the eventual channel should be 255.
            if value.isNaN || value <= 0 { return 0 }
            if value >= 1 { return 255 }
            return UInt32((value * 255.0).rounded())
        }

        return (component(red) << 16) | (component(green) << 8) | component(blue)
    }

    func packedRGBKey(from value: Any) -> UInt32? {
#if canImport(AppKit)
        guard let color = value as? NSColor else { return nil }
        if color.type == .componentBased, color.colorSpace.colorSpaceModel == .rgb {
            return packedRGBKey(
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent
            )
        }
        guard let rgb = color.usingColorSpace(.genericRGB) ?? color.usingColorSpace(.sRGB) else {
            return nil
        }
        return packedRGBKey(
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent
        )
#elseif canImport(UIKit)
        guard let color = value as? UIColor else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return packedRGBKey(red: red, green: green, blue: blue)
#else
        return nil
#endif
    }

    func packedRGBKey(fromHexKey hexKey: String) -> UInt32? {
        guard hexKey.utf8.count == 6 else { return nil }
        var result: UInt32 = 0
        for character in hexKey.utf8 {
            let digit: UInt8
            switch character {
            case 48...57:
                digit = character - 48
            case 65...70:
                digit = character - 55
            default:
                return nil
            }
            result = (result << 4) | UInt32(digit)
        }
        return result
    }

    func platformColor(_ color: TokenColor) -> Any {
#if canImport(AppKit)
        NSColor(
            srgbRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1
        )
#elseif canImport(UIKit)
        UIColor(
            red: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1
        )
#else
        color.hexString
#endif
    }
}

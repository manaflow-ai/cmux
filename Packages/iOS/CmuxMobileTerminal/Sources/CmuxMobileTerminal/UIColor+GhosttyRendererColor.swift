#if canImport(UIKit)
import CoreGraphics
import UIKit

extension UIColor {
    /// Converts Ghostty's sRGB config colors into the Display P3 space used by its IOSurface renderer.
    static func ghosttyRendererColor(srgbRed red: UInt8, green: UInt8, blue: UInt8, alpha: CGFloat = 1.0) -> UIColor {
        let fallback = UIColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
        guard let sourceSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let targetSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let sourceColor = CGColor(
                  colorSpace: sourceSpace,
                  components: [
                      CGFloat(red) / 255.0,
                      CGFloat(green) / 255.0,
                      CGFloat(blue) / 255.0,
                      alpha,
                  ]
              ),
              let convertedColor = sourceColor.converted(to: targetSpace, intent: .defaultIntent, options: nil) else {
            return fallback
        }
        return UIColor(cgColor: convertedColor)
    }

    func convertedToGhosttyRendererColorSpace() -> UIColor {
        guard let targetSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let convertedColor = cgColor.converted(to: targetSpace, intent: .defaultIntent, options: nil) else {
            return self
        }
        return UIColor(cgColor: convertedColor)
    }
}
#endif

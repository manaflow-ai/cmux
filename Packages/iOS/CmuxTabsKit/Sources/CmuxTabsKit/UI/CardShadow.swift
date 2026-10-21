#if os(iOS)
import SwiftUI
import UIKit

/// A card's drop shadow as a stretchable image (drawn once per radius):
/// one plain image layer, where a SwiftUI `.shadow` on the clipped card
/// cost an offscreen pass per card on every scroll frame. Matches
/// `.shadow(color: .black.opacity(0.08), radius: 10, y: 3)`.
struct CardShadow: View {
    var radius: CGFloat
    @Environment(\.displayScale) private var displayScale

    static let blurRadius: CGFloat = 10
    static let opacity: CGFloat = 0.08
    static let y: CGFloat = 3
    /// Room around the card for the blur.
    static let margin: CGFloat = 2.5 * blurRadius

    var body: some View {
        let (image, cap) = Self.image(radius: radius, scale: displayScale)
        Image(uiImage: image)
            .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap), resizingMode: .stretch)
            .padding(-Self.margin)
            .offset(y: Self.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @MainActor private static var cache: [CGFloat: (UIImage, CGFloat)] = [:]

    @MainActor static func image(radius: CGFloat, scale: CGFloat) -> (UIImage, CGFloat) {
        let key = (radius * 100).rounded() + scale / 10
        if let hit = cache[key] { return hit }
        // The shape's straight edges must be longer than the blur reaches
        // past a corner, so the stretched middle has the straight-edge profile.
        let k = (radius + 2 * blurRadius).rounded(.up)
        let side = 2 * k + 1
        let size = CGSize(width: side + 2 * margin, height: side + 2 * margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let shape = UIBezierPath(roundedRect: CGRect(x: margin, y: margin, width: side, height: side), cornerRadius: radius)
            // CALayer's shadowRadius is half of Core Graphics' blur.
            cg.setShadow(offset: .zero, blur: 2 * blurRadius, color: UIColor.black.withAlphaComponent(opacity).cgColor)
            UIColor.black.setFill()
            shape.fill()
            // Keep only the shadow: the card covers its own rect.
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setBlendMode(.clear)
            shape.fill()
        }
        let entry = (image, margin + k)
        cache[key] = entry
        return entry
    }
}
#endif

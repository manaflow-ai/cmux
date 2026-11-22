public import CmuxNextBrowserCore
public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

extension BrowserDesignModeCard {
    /// The card's element cut from `image` (the page as shown, ``BrowserTab/designModeSnapshot()``),
    /// as PNG; nil when it is off the page or empty.
    public func crop(from image: CGImage) -> Data? {
        guard viewportWidth > 0 else { return nil }
        let scale = Double(image.width) / viewportWidth
        let rect = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
                          width: bounds.width * scale, height: bounds.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cut = image.cropping(to: rect) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cut, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

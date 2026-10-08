import AppKit
import CmuxNextIcons
import Testing
@testable import CmuxNextTabs

/// Tab kind icons come from the cmux icon pack and fill the tab's icon box
/// (an SF Symbol at the small icon size left them visibly too small).
@MainActor @Suite struct TabPackIconTests {
    @Test func aPackIconFillsTheIconBoxAtEachScale() throws {
        for scale in [CGFloat(1), 2] {
            let image = try #require(TabPackIconCache.shared.image(name: .terminal, tint: .white, size: 16, scale: scale))
            #expect(image.width == Int(16 * scale))
            let ink = try #require(Self.inkBounds(image))
            // The pack draws on a 24 grid with about 3 units of margin.
            #expect(ink.height >= 0.6 * CGFloat(image.height))
            #expect(ink.width >= 0.6 * CGFloat(image.width))
        }
    }

    @Test func aPackIconIsTintedAndCached() throws {
        let first = try #require(TabPackIconCache.shared.image(name: .browser, tint: .red, size: 16, scale: 2))
        let again = try #require(TabPackIconCache.shared.image(name: .browser, tint: .red, size: 16, scale: 2))
        #expect(first === again)
        let other = try #require(TabPackIconCache.shared.image(name: .browser, tint: .blue, size: 16, scale: 2))
        #expect(first !== other)
    }

    /// The box around pixels with any alpha.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

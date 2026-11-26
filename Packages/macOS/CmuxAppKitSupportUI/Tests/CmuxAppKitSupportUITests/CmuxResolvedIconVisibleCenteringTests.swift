import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Icon buttons draw a symbol inside a fixed canvas. SF Symbol layout boxes
/// carry uneven padding, so a glyph centered by its layout box can sit a pixel
/// off center. With `centersVisibleContent`, the visible pixels must land on
/// the canvas center.
@MainActor
@Suite struct CmuxResolvedIconVisibleCenteringTests {
    private static let canvas = NSSize(width: 22, height: 20)

    @Test(arguments: ["trash", "arrow.counterclockwise", "plus", "xmark", "ellipsis"])
    func visibleContentIsCenteredInCanvas(systemName: String) throws {
        let renderer = CmuxResolvedIconRenderer()
        let appearance = try #require(NSAppearance(named: .aqua))
        let image = try #require(renderer.image(
            for: CmuxResolvedIconRequest(
                source: .systemSymbol(name: systemName, accessibilityDescription: nil),
                size: Self.canvas,
                tintColor: .labelColor,
                symbolWeight: .medium,
                symbolPointSize: 11,
                centersVisibleContent: true
            ),
            appearance: appearance
        ))
        #expect(image.size == Self.canvas)

        let rendered = try #require(bitmap(of: image))
        let margins = try #require(visibleMargins(in: rendered))
        // An odd leftover pixel goes to the right and bottom, so a glyph
        // never reads low or left of the canvas center.
        #expect(margins.left == (margins.left + margins.right) / 2, "\(systemName) \(margins)")
        #expect(margins.top == (margins.top + margins.bottom) / 2, "\(systemName) \(margins)")
    }

    @Test func centeringKeepsEveryVisiblePixel() throws {
        let renderer = CmuxResolvedIconRenderer()
        let appearance = try #require(NSAppearance(named: .aqua))
        func request(centered: Bool) -> CmuxResolvedIconRequest {
            CmuxResolvedIconRequest(
                source: .systemSymbol(name: "trash", accessibilityDescription: nil),
                size: Self.canvas,
                tintColor: .labelColor,
                symbolWeight: .medium,
                symbolPointSize: 11,
                centersVisibleContent: centered
            )
        }
        let plainImage = try #require(renderer.image(for: request(centered: false), appearance: appearance))
        let centeredImage = try #require(renderer.image(for: request(centered: true), appearance: appearance))
        let plain = try #require(bitmap(of: plainImage))
        let centered = try #require(bitmap(of: centeredImage))
        #expect(totalAlpha(in: centered) == totalAlpha(in: plain))
    }

    private struct Margins: CustomStringConvertible {
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int
        var description: String { "L\(left) R\(right) T\(top) B\(bottom)" }
    }

    private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private func visibleMargins(in bitmap: NSBitmapImageRep) -> Margins? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return Margins(
            left: minX,
            right: bitmap.pixelsWide - 1 - maxX,
            top: minY,
            bottom: bitmap.pixelsHigh - 1 - maxY
        )
    }

    private func totalAlpha(in bitmap: NSBitmapImageRep) -> Int {
        var total = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                total += Int(((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
            }
        }
        return total
    }
}

import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Isolates the field's outer rim from the compositor's glass, which cannot render offscreen.
/// The gallery compares the old square rim, the rounded rim, and a thinner rounded alternative
/// (left to right), with single-line and expanded drafts (top to bottom). Live app captures
/// remain the evidence for glass and colors.
@MainActor @Suite(.serialized) struct HomeComposerBorderTests {
    private func rim(height: CGFloat, variant: Int? = nil) throws -> CGImage {
        let chrome = FieldChrome(frame: NSRect(x: 0, y: 0, width: 240, height: height))
        chrome.field.frame = chrome.bounds
        chrome.applyTheme(light: true, symbol: .black, edge: .black)
        let layer = try #require(chrome.field.layer)
        // Render the actual backing layer's border without the system-managed glass internals.
        layer.sublayers?.forEach { $0.isHidden = true }
        layer.backgroundColor = nil
        if let variant {
            layer.cornerRadius = variant == 0 ? 0 : chrome.field.cornerRadius
            layer.borderWidth = variant == 2 ? 0.5 : 1
        }
        let context = try #require(CGContext(
            data: nil, width: 480, height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return try #require(context.makeImage())
    }

    @Test(arguments: [CGFloat(30), CGFloat(90)])
    func theOutlineFollowsTheRoundedField(height: CGFloat) throws {
        let image = try rim(height: height)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        // A square outline paints the top-left corner; the rounded outline leaves it clear
        // while retaining the straight upper edge. This fails on the old glass backing layer.
        #expect(bytes[3] == 0)
        #expect(bytes[(image.width / 2) * 4 + 3] > 200)
    }

    @Test func switchingToDarkRemovesTheExtraOutline() throws {
        let chrome = FieldChrome(frame: .zero)
        chrome.applyTheme(light: true, symbol: .black, edge: .black)
        chrome.applyTheme(light: false, symbol: .white, edge: .white)
        #expect(try #require(chrome.field.layer).borderWidth == 0)
    }

    @Test func borderGallery() throws {
        let context = try #require(CGContext(
            data: nil, width: 1520, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1520, height: 320))
        for variant in 0..<3 {
            for height: CGFloat in [30, 90] {
                let image = try rim(height: height, variant: variant)
                context.draw(image, in: CGRect(x: 20 + variant * 500, y: height == 30 ? 240 : 20,
                                              width: 480, height: Int(height * 2)))
            }
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = package.appendingPathComponent(".build/composer-border-gallery.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

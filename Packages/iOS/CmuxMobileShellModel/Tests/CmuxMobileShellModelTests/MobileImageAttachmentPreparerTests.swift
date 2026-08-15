import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CmuxMobileShellModel

@Suite("Mobile image attachment preparation")
struct MobileImageAttachmentPreparerTests {
    @Test func thumbnailSupportsLargeRetinaComposerPreview() async throws {
        let sourceURL = try makeImageFixture(width: 1_200, height: 800)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = await MobileImageAttachmentPreparer().prepare(url: sourceURL)
        let attachment = try #require(prepared)
        let thumbnailData = try #require(attachment.thumbnailData)
        let thumbnailSource = try #require(
            CGImageSourceCreateWithData(thumbnailData as CFData, nil)
        )
        let thumbnail = try #require(
            CGImageSourceCreateImageAtIndex(thumbnailSource, 0, nil)
        )

        #expect(
            max(thumbnail.width, thumbnail.height) >= 320,
            "The staged preview needs enough pixels for a large Retina attachment card"
        )
    }

    private func makeImageFixture(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.94, green: 0.18, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.08, green: 0.46, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))

        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-image-preparer-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

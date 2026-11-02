#if canImport(ImageIO)
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

    @Test func sourceOverFormerEightMiBLimitIsReencodedAndAccepted() async throws {
        let sourceURL = try makeNoisyImageFixture(width: 2_400, height: 2_400)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        #expect(
            ((try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.intValue ?? 0)
                > MobileImageAttachmentPreparer.maximumEncodedBytes
        )

        let prepared = try #require(await MobileImageAttachmentPreparer().prepare(url: sourceURL))
        #expect(prepared.data.count <= MobileImageAttachmentPreparer.maximumEncodedBytes)
        #expect(["png", "jpg"].contains(prepared.format))
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

    private func makeNoisyImageFixture(width: Int, height: Int) throws -> URL {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            var state: UInt32 = 0x1234_5678
            for index in stride(from: 0, to: raw.count, by: 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                raw[index] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                raw[index + 1] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                raw[index + 2] = UInt8(truncatingIfNeeded: state >> 24)
                raw[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-image-preparer-noisy-\(UUID().uuidString).png")
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
#endif

import AppKit
@testable import CmuxNextCompat
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The image seams of p02-threads-145 (``CheckedImageSource``, ``blockingNSImage(_:fileID:line:)``): they return
/// what the plain ImageIO and AppKit calls return; on the main thread an image above
/// ``BlockingKind/cpuIntensiveImageBytes`` is one ``BlockingKind/cpuIntensive`` site at the caller's line, a small
/// one and the header reads are none, and off the main thread nothing records. Each test binds its own table
/// (``BlockingViolationTable/scoped``).
@Suite(.serialized)
struct CheckedImageSourceSeamTests {
    /// The seams answer as the plain calls do, for a small and a large image (off the main thread, so the large
    /// calls record nothing in the process's table).
    @Test nonisolated func theSeamsReturnThePlainCallsResults() throws {
        for side in [ImageFixture.smallSide, ImageFixture.largeSide] {
            let png = try ImageFixture.png(side: side)
            let source = try #require(CheckedImageSource(png, options: [kCGImageSourceShouldCache: false]))
            #expect(source.byteCount == png.count)
            #expect(source.type == UTType.png.identifier)
            #expect(source.count == 1)
            #expect(source.properties()?[kCGImagePropertyPixelWidth] as? Int == side)
            #expect(source.image()?.width == side)
            #expect(source.image(at: 1) == nil)
            let thumbnail = source.thumbnail(options: ImageFixture.thumbnailOptions)
            #expect(thumbnail.map { max($0.width, $0.height) } == min(side, ImageFixture.thumbnailSide))
            #expect(blockingNSImage(png)?.size == NSImage(data: png)?.size)
        }
        #expect(CheckedImageSource(Data("not an image".utf8))?.image() == nil)
        #expect(blockingNSImage(Data("not an image".utf8)) == nil)
    }

    /// A file opens through the checked read and decodes as the data does; a missing file is nil.
    @Test nonisolated func aFileOpensThroughTheCheckedRead() throws {
        let png = try ImageFixture.png(side: ImageFixture.smallSide)
        let url = FileManager.default.temporaryDirectory.appending(path: "checked-image-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png.write(to: url)
        let source = try #require(CheckedImageSource(blockingContentsOf: url))
        #expect(source.byteCount == png.count)
        #expect(source.image()?.width == ImageFixture.smallSide)
        #expect(CheckedImageSource(blockingContentsOf: url.appendingPathExtension("missing")) == nil)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Above the gate on the main thread, each decode is one cpu-intensive site at its caller's line; opening the
    /// source and reading its header are none.
    @MainActor @Test func aLargeDecodeOnTheMainThreadRecordsOneSiteEach() async throws {
        let table = BlockingViolationTable(mode: .record)
        let png = try ImageFixture.png(side: ImageFixture.largeSide)
        try #require(png.count > BlockingKind.cpuIntensiveImageBytes)
        let expected = try BlockingViolationTable.$scoped.withValue(table) {
            let source = try #require(CheckedImageSource(png))
            _ = (source.type, source.count, source.properties())
            return [
                ImageFixture.site { _ = source.image() },
                ImageFixture.site { _ = source.thumbnail(options: ImageFixture.thumbnailOptions) },
                ImageFixture.site { _ = blockingNSImage(png) },
            ]
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.location).sorted() == expected.sorted())
        #expect(sites.allSatisfy { $0.kind == .cpuIntensive && $0.context == .main && $0.count == 1 })
    }

    /// A small image decodes on the main thread with no site.
    @MainActor @Test func aSmallDecodeOnTheMainThreadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let png = try ImageFixture.png(side: ImageFixture.smallSide)
        try BlockingViolationTable.$scoped.withValue(table) {
            let source = try #require(CheckedImageSource(png))
            _ = source.image()
            _ = source.thumbnail(options: ImageFixture.thumbnailOptions)
            _ = blockingNSImage(png)
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// Off the main thread a large decode records nothing: that is where it belongs.
    @Test nonisolated func aLargeDecodeOffTheMainThreadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let png = try ImageFixture.png(side: ImageFixture.largeSide)
        let queue = DispatchQueue(label: "test.checked-image-source")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                BlockingViolationTable.$scoped.withValue(table) {
                    _ = CheckedImageSource(png)?.image()
                    _ = blockingNSImage(png)
                }
                done.resume()
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #endif
}

/// Images of a chosen size, the same on every run.
private nonisolated enum ImageFixture {
    /// 400 by 400 pixels of noise encode to about 470 KiB of PNG, above the 256 KiB gate.
    static let largeSide = 400
    /// Well under 1 KiB of PNG.
    static let smallSide = 4
    /// The longest side ``thumbnailOptions`` asks for.
    static let thumbnailSide = 16
    static var thumbnailOptions: [CFString: Any] {
        [kCGImageSourceThumbnailMaxPixelSize: thumbnailSide, kCGImageSourceCreateThumbnailFromImageAlways: true]
    }

    /// Runs `call`, written on the caller's line, and names that line as a site's location (`fileID:line`).
    static func site(fileID: StaticString = #fileID, line: UInt = #line, _ call: () -> Void) -> String {
        call()
        return "\(fileID):\(line)"
    }

    /// A `side` by `side` PNG of noise (xorshift from a fixed seed, so it does not compress).
    static func png(side: Int) throws -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let pixels = Data((0..<side * side * 4).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}

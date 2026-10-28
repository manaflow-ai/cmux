import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import CmuxNextWakeups

/// `debug.window_snapshot` keeps AppKit capture on the main actor but hands the
/// immutable image to the off-main PNG encoder. This exercises the encoder's
/// real ImageIO and file path from a main-actor caller.
@MainActor
@Suite
struct DebugWindowSnapshotPNGTests {
    @Test
    func encodesAndWritesPNGFromMainActor() async throws {
        let width = 64
        let height = 48
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-window-snapshot-test-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("snapshot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try await NSWindow.encodeSnapshotPNG(image, to: url, on: BackgroundWork())

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }
}

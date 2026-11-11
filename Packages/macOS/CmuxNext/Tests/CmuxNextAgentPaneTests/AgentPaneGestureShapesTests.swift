import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextAgentPane

/// The image sizes the host tells the page as a drop, paste or pick goes to it, read from each file's
/// header (Leo, 2026-11-11: "if you're literally just pointing to a file path, why would it ever take
/// time to load anything anyways?").
struct AgentPaneGestureShapesTests {
    /// A PNG of `width` x `height` written to a fresh temporary folder.
    private func png(_ name: String, width: Int, height: Int, orientation: Int? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func readsEachImagesSizeAndSkipsOtherFiles() throws {
        let wide = try png("wide.png", width: 288, height: 180)
        let tall = try png("tall.png", width: 90, height: 288)
        let text = wide.deletingLastPathComponent().appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        #expect(
            AgentPaneGestureShapes.shapes(of: [wide, text, tall]) == [
                .init(name: "wide.png", width: 288, height: 180),
                .init(name: "tall.png", width: 90, height: 288),
            ])
    }

    @Test func aQuarterTurnedImageShowsHeightByWidth() throws {
        let turned = try png("turned.png", width: 300, height: 100, orientation: 6)
        #expect(AgentPaneGestureShapes.shapes(of: [turned]) == [.init(name: "turned.png", width: 100, height: 300)])
    }

    /// A movie's `tkhd` box (version 0) of `width` x `height`, a quarter turned or not, in a `moov`
    /// written after an empty `mdat`, as a screen recording writes it.
    private func movie(width: UInt32, height: UInt32, turned: Bool) throws -> URL {
        func box(_ type: String, _ body: Data) -> Data {
            var size = UInt32(8 + body.count).bigEndian
            return Data(bytes: &size, count: 4) + Data(type.utf8) + body
        }
        func u32(_ value: UInt32) -> Data { var big = value.bigEndian; return Data(bytes: &big, count: 4) }
        var tkhd = Data(count: 40)
        // The matrix: a, b, u, c, d, v, x, y, w.
        tkhd += turned ? u32(0) + u32(0x10000) : u32(0x10000) + u32(0)
        tkhd += u32(0) + (turned ? u32(0xFFFF_0000) + u32(0) : u32(0) + u32(0x10000)) + u32(0) + u32(0) + u32(0) + u32(0x4000_0000)
        tkhd += u32(width << 16) + u32(height << 16)
        let file = box("ftyp", Data("qt  ".utf8)) + box("mdat", Data(count: 32)) + box("moov", box("trak", box("tkhd", tkhd)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try file.write(to: url)
        return url
    }

    @Test func readsAMoviesSizeFromItsTrackHeaderAfterItsMedia() throws {
        #expect(AgentPaneGestureShapes.videoSize(try movie(width: 1920, height: 1080, turned: false))! == (1920, 1080))
        #expect(AgentPaneGestureShapes.videoSize(try movie(width: 1920, height: 1080, turned: true))! == (1080, 1920))
        let named = try movie(width: 1280, height: 800, turned: false)
        #expect(AgentPaneGestureShapes.shapes(of: [named]) == [.init(name: named.lastPathComponent, width: 1280, height: 800)])
    }

    @Test func aMissingFileGivesNone() {
        #expect(AgentPaneGestureShapes.shapes(of: [URL(fileURLWithPath: "/nonexistent/\(UUID()).png")]).isEmpty)
    }

    @Test func theScriptCarriesTheGesturesKindAndShapes() throws {
        #expect(AgentPaneGestureShapes.script([], kind: .paste, at: 1) == nil)
        let script = try #require(AgentPaneGestureShapes.script([.init(name: nil, width: 4, height: 3)], kind: .choose, at: 1))
        #expect(script.hasPrefix("window.__cmuxAttachShapes = {"))
        #expect(script.contains("\"kind\":\"choose\""))
        #expect(script.contains("\"width\":4"))
        #expect(script.hasSuffix("window.dispatchEvent(new Event('cmux-attach-shapes'));"))
    }
}

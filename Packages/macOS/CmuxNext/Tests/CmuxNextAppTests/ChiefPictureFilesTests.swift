@testable import CmuxNextHomeEngine
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The default Chief's own picture (backgrounds plan phase 4): Choose Picture… draws a still at
/// 512 px or keeps a GIF as it is beside profile.json, the header and tile read it (GIF and WebP
/// included), and Use Default Picture goes back to the bundled cat.
@Suite struct ChiefPictureFilesTests {
    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-picture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `width`×`height` picture of `frames` frames as `type`.
    static func picture(_ type: UTType, width: Int, height: Int, frames: Int = 1, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: CGFloat(frame), green: 0.5, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aProfileMayNameAGIFOrWebPPicture() {
        for name in ["cat.png", "cat.JPG", "cat.heic", "cat.gif", "cat.webp"] { #expect(HomeChiefFiles.namesPicture(name), "\(name)") }
        for name in ["AB", "🐱", "../cat.png", "cat.svg"] { #expect(!HomeChiefFiles.namesPicture(name), "\(name)") }
    }

    @Test func aStillIsDrawnSmallAndAGIFKeptAsItIs() throws {
        let home = try Self.home(), source = try Self.home()
        let files = HomeChiefFiles(muxHome: home)
        let photo = source.appendingPathComponent("photo.jpg")
        try Self.picture(.jpeg, width: 3000, height: 2000, to: photo)
        try files.writePicture(from: photo)
        let folder = home.appendingPathComponent("optchat")
        let png = folder.appendingPathComponent("avatar.png")
        let drawn = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(drawn.width, drawn.height) == 512, "a large photo was kept at \(drawn.width)×\(drawn.height)")
        #expect(files.avatar() == "avatar.png")
        #expect(files.headerAvatar().picture != nil)
        guard case .picture = files.tileAvatar() else {
            Issue.record("the tile shows no picture")
            return
        }

        let gif = source.appendingPathComponent("wave.gif")
        try Self.picture(.gif, width: 64, height: 64, frames: 3, to: gif)
        try files.writePicture(from: gif)
        #expect(files.avatar() == "avatar.gif")
        #expect(try Data(contentsOf: folder.appendingPathComponent("avatar.gif")) == Data(contentsOf: gif), "the GIF was redrawn")
        #expect(!FileManager.default.fileExists(atPath: png.path), "the earlier picture was left behind")
        let frames = CGImageSourceCreateWithURL(folder.appendingPathComponent("avatar.gif") as CFURL, nil).map(CGImageSourceGetCount)
        #expect(frames == 3, "the GIF lost its motion")
    }

    @Test func aFileThatIsNotAPictureChangesNothing() throws {
        let home = try Self.home(), source = try Self.home()
        let files = HomeChiefFiles(muxHome: home)
        files.writeAvatar("AB")
        let notes = source.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: notes)
        #expect(throws: (any Error).self) { try files.writePicture(from: notes) }
        #expect(files.avatar() == "AB")
    }

    @Test func useDefaultPictureGoesBackToTheCat() throws {
        let home = try Self.home(), source = try Self.home()
        let files = HomeChiefFiles(muxHome: home)
        let photo = source.appendingPathComponent("photo.png")
        try Self.picture(.png, width: 100, height: 100, to: photo)
        try files.writePicture(from: photo)
        files.clearPicture()
        #expect(files.avatar() == nil)
        #expect(files.tileAvatar() == nil, "the tile does not fall back to the bundled cat")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("optchat/avatar.png").path))
    }

    /// The tile (backgrounds plan phase 5 review): a square GIF file is kept as it is (the sidebar
    /// draws its first frame); a non-square one gets a still square copy rather than being stretched.
    @Test func aSquareGIFIsKeptAndAWideOneGetsAStillSquareTile() throws {
        let home = try Self.home(), source = try Self.home()
        let files = HomeChiefFiles(muxHome: home)
        let square = source.appendingPathComponent("square.gif")
        try Self.picture(.gif, width: 64, height: 64, frames: 3, to: square)
        try files.writePicture(from: square)
        guard case .picture(let kept) = files.tileAvatar() else {
            Issue.record("no tile picture")
            return
        }
        #expect(kept.pathExtension == "gif")
        #expect(CGImageSourceCreateWithURL(kept as CFURL, nil).map(CGImageSourceGetCount) == 3, "a square GIF was redrawn")
        let wide = source.appendingPathComponent("wide.gif")
        try Self.picture(.gif, width: 96, height: 48, frames: 3, to: wide)
        try files.writePicture(from: wide)
        guard case .picture(let tile) = files.tileAvatar() else {
            Issue.record("no tile picture")
            return
        }
        #expect(tile.pathExtension == "png")
        let frame = try #require(CGImageSourceCreateWithURL(tile as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(frame.width == frame.height)
    }
}

import AppKit
@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing

/// The Desktop Wallpaper tile and window backdrop resolve what macOS reports to a picture that
/// decodes: macOS can name a deleted file (a picture in `/tmp`), a folder or a description.
struct DesktopPictureTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-picture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func writePNG(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixel(_ url: URL) throws -> (Int, Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    @Test func aReadablePictureIsUsedAsIs() throws {
        let picture = try writePNG("Desk.png")
        let resolved = DesktopPicture(reportedURL: picture, fillColor: nil, fallbackFolder: folder).resolvedURL()
        #expect(resolved == picture)
    }

    @Test func aDeletedPictureBecomesTheFillColorNotNothing() throws {
        // What this Mac reported: /tmp/cmux-solid-grey.png, a file that no longer exists.
        let gone = folder.appendingPathComponent("cmux-solid-grey.png")
        let fill = NSColor(srgbRed: 0.254902, green: 0.411765, blue: 0.666667, alpha: 1)
        let resolved = try #require(DesktopPicture(reportedURL: gone, fillColor: fill, fallbackFolder: folder).resolvedURL())
        #expect(resolved != gone)
        let (red, green, blue) = try pixel(resolved)
        #expect(abs(red - 65) <= 2 && abs(green - 105) <= 2 && abs(blue - 170) <= 2)
    }

    @Test func noReportedPictureStillResolves() throws {
        let resolved = try #require(DesktopPicture(reportedURL: nil, fillColor: nil, fallbackFolder: folder).resolvedURL())
        #expect(CGImageSourceCreateWithURL(resolved as CFURL, nil) != nil)
    }

    @Test func aFolderResolvesToAPictureInIt() throws {
        let rotation = folder.appendingPathComponent("Rotation", isDirectory: true)
        try FileManager.default.createDirectory(at: rotation, withIntermediateDirectories: true)
        try Data("not a picture".utf8).write(to: rotation.appendingPathComponent("a-notes.txt"))
        let picture = try writePNG("b-picture.png", in: rotation)
        // Listing the folder spells the temporary directory /private/var; compare resolved paths.
        let resolved = DesktopPicture(reportedURL: rotation, fillColor: nil, fallbackFolder: folder).resolvedURL()
        #expect(resolved?.resolvingSymlinksInPath().path == picture.resolvingSymlinksInPath().path)
    }

    @Test func aFileThatIsNotAPictureFallsBack() throws {
        let description = folder.appendingPathComponent("Sequoia.madesktop")
        try Data("<plist/>".utf8).write(to: description)
        let resolved = try #require(DesktopPicture(reportedURL: description, fillColor: nil, fallbackFolder: folder).resolvedURL())
        #expect(resolved != description)
        #expect(CGImageSourceCreateWithURL(resolved as CFURL, nil).flatMap(CGImageSourceGetType) != nil)
    }
}

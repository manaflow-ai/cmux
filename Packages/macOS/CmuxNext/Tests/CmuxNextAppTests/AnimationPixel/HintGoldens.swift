import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The golden images of the hold-Cmd hint chips, committed under Tests/Fixtures/animation-pixel-goldens/ (outside every target), one
/// per macOS major (Liquid Glass draws differently on 26 and 27), appearance, scale and state.
///
/// A golden changes only in its own commit, with the reason and an independent reviewer receipt
/// (cmux-ad 2026-11-01, rule 5). A missing golden FAILS its test and writes what was captured to
/// `artifacts/animation-pixel-goldens/` (and a tar of that folder), for that commit.
struct HintGoldens {
    struct Image {
        let width: Int
        let height: Int
        /// BGRA, row-major, top row first.
        let pixels: [UInt32]
    }

    static var folder: URL {
        DeclaredSpring.repositoryRoot.appendingPathComponent("Packages/macOS/CmuxNext/Tests/Fixtures/animation-pixel-goldens")
    }

    static var captureFolder: URL {
        DeclaredSpring.repositoryRoot.appendingPathComponent("artifacts/animation-pixel-goldens")
    }

    static func name(_ state: String, dark: Bool, scale: Int) -> String {
        "cmd-hints-macos\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)-\(dark ? "dark" : "light")-\(scale)x-\(state).png"
    }

    static func load(_ name: String) -> Image? {
        let url = folder.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return pixels(of: image)
    }

    /// Writes `image` into the capture folder as `name` and refreshes the folder's tar.
    static func capture(_ image: Image, as name: String) throws {
        try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        let url = captureFolder.appendingPathComponent(name)
        guard let cg = cgImage(image), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DeclaredSpring.Failure(description: "cannot write \(url.path)")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw DeclaredSpring.Failure(description: "cannot write \(url.path)") }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = captureFolder.deletingLastPathComponent()
        tar.arguments = ["cf", "animation-pixel-goldens.tar", "animation-pixel-goldens"]
        try tar.run()
        tar.waitUntilExit()
    }

    static func pixels(of image: CGImage) -> Image {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    static func cgImage(_ image: Image) -> CGImage? {
        let data = image.pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

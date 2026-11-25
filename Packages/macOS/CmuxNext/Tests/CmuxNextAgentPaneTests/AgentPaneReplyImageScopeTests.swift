@testable import CmuxNextAgentPane
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Reply image paths have a read-only local scope separate from ordinary path chips, and large
/// RGBA PNGs are normalized before the page or its viewer receives them.
struct AgentPaneReplyImageScopeTests {
    @Test func imageRootsDoNotWidenOrdinaryPathChips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reply-image-scope-\(UUID().uuidString)", isDirectory: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reply-image-scope-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data([0]).write(to: home.appendingPathComponent("sidebar.png"))
        try Data([0]).write(to: tmp.appendingPathComponent("sidebar.png"))
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: tmp)
        }

        // Use the real temporary directory as the fixture's `/tmp` image root; the production
        // model supplies `/tmp`, which is canonicalized by the host to the same directory.
        let paths = AgentPaneReplyPaths(roots: [project.path], imageRoots: [home.path, tmp.path], home: home.path, base: project.path)
        #expect(paths.resolve(tmp.appendingPathComponent("sidebar.png").path)?.place == .outside)
        #expect(paths.resolveImage(tmp.appendingPathComponent("sidebar.png").path)?.place == .root)
        #expect(paths.resolveImage(home.appendingPathComponent("sidebar.png").path)?.place == .root)
        #expect(AgentPaneReplyPaths.isImagePath("file://\(tmp.appendingPathComponent("sidebar.png").path)"))
        #expect(!AgentPaneReplyPaths.isImagePath("file://other-host/tmp/sidebar.png"))
        #expect(paths.resolveImage("/var/tmp/sidebar.png")?.place == .outside)
        #expect(paths.resolveImage(tmp.appendingPathComponent("sidebar.dat").path) == nil)
        #expect(paths.resolveImage(tmp.appendingPathComponent("sidebar.png#preview").path)?.place == .root)
    }

    @Test func aLargeRGBAImageBecomesABoundedVisibleSRGBPNG() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reply-image-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sidebar-clean-cmux.png")
        try Self.largePNG.write(to: file)

        let result = await AgentPaneReplyImages.local(file.path)
        guard case .success(let source) = result, let comma = source.firstIndex(of: ","),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...])) else {
            Issue.record("large PNG did not become a data URL: \(result)")
            return
        }
        let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width <= AgentPaneReplyImages.maximumSide)
        #expect(image.height > 0)
        let rep = NSBitmapImageRep(cgImage: image)
        let color = rep.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB)
        #expect(color?.blueComponent ?? 0 > 0.5)
        #expect(color?.redComponent ?? 0 < 0.2)
    }

    private static let largePNG: Data = {
        let width = 3708, height = 2468
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }()
}

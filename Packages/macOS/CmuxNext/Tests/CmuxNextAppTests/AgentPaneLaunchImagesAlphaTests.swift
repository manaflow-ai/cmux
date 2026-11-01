import AppKit
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// The saved page that is the pane's first frame at launch (`AgentPaneLaunchImages`) keeps a
/// transparent page's clear pixels: the New Tab page over a background image showed the solid
/// theme color first, because the image was a JPEG, which has no alpha.
@MainActor
struct AgentPaneLaunchImagesAlphaTests {
    /// An 8x8 image at 2x: clear but for its top row when `clear`, else opaque gray throughout.
    private static func image(clear: Bool) throws -> NSImage {
        let info = clear ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(clear ? CGRect(x: 0, y: 7, width: 8, height: 1) : CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    /// The saved pages of `directory` as the next launch reads them (before its first pane asks).
    private static func launch(_ directory: URL) async -> AgentPaneLaunchImages {
        let images = AgentPaneLaunchImages(directory: directory)
        await images.prefetch(on: BackgroundWork(label: "test.launch-images"))?.value
        return images
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "launch-images-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func alpha(_ image: NSImage, x: Int, y: Int) throws -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        return try #require(rep.colorAt(x: x, y: y)).alphaComponent
    }

    @Test func aTransparentPageComesBackWithItsClearPixels() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await AgentPaneLaunchImages(directory: directory).save(["tab_a": try Self.image(clear: true)])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "tab_a@2x.png").path))
        let image = try #require(await Self.launch(directory).take("tab_a"))
        #expect(image.size == NSSize(width: 4, height: 4))
        #expect(try Self.alpha(image, x: 4, y: 4) == 0)
        #expect(try Self.alpha(image, x: 4, y: 0) == 1)
    }

    @Test func anOpaquePageStaysAJPEG() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await AgentPaneLaunchImages(directory: directory).save(["tab_b": try Self.image(clear: false)])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "tab_b@2x.jpg").path))
        let image = try #require(await Self.launch(directory).take("tab_b"))
        #expect(try Self.alpha(image, x: 4, y: 4) == 1)
    }

    @Test func aReleasedTransparentPageIsHeldWithItsClearPixels() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        let frame = try #require(try Self.image(clear: true).cgImage(forProposedRect: nil, context: nil, hints: nil))
        await images.hold("tab_c", frame, size: NSSize(width: 4, height: 4), appearance: nil)
        let image = try #require(images.take("tab_c"))
        #expect(try Self.alpha(image, x: 4, y: 4) == 0)
    }

    /// A saved picture that keeps clear pixels stands in for its page in any scope (`takeCovering`, the pane's first
    /// frame, with `AgentPaneView.savedPictureCovers`'s rule), and like `take` it is handed out once.
    @Test func aSavedPictureWithClearPixelsCoversItsPageOnce() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await AgentPaneLaunchImages(directory: directory).save(["tab_d": try Self.image(clear: true)])
        let images = await Self.launch(directory), scope = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(images.takeCovering("tab_d", newTab: false, size: .zero, appearance: nil, in: scope))
        #expect(try Self.alpha(image, x: 4, y: 4) == 0)
        #expect(images.takeCovering("tab_d", newTab: false, size: .zero, appearance: nil, in: scope) == nil)
    }
}

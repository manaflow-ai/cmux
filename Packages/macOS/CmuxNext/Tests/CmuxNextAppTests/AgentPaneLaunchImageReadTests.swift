import AppKit
import Foundation
import Testing
@testable import CmuxNextApp

/// Slice (c) of the main-thread sweep: an agent pane's saved page from the last quit (`AgentPaneLaunchImages`,
/// up to 8 MB per pane) was read from disk and decoded on the main thread as the pane was built at launch.
@MainActor @Suite(.serialized)
struct AgentPaneLaunchImageReadTests {
    /// An opaque gray 8x8 image at 2x.
    static func page() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    /// The tag state's page directory, saved at the last quit with tab `key`'s page.
    static func saved(_ key: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        await AgentPaneLaunchImages(directory: directory).save([key: try page()])
        return directory
    }

    @Test func aSavedPageIsReadOffTheMainThread() async throws {
        let directory = try await Self.saved("tab_a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe()
        let page = AgentPaneLaunchImages(directory: directory, reader: probe.reader).take("tab_a")
        #expect(page?.size == NSSize(width: 4, height: 4))
        #expect(probe.reads == [false], "the saved page was read on the main thread")
    }
}

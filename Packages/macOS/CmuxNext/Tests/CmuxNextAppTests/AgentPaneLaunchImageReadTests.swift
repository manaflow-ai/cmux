import AppKit
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Testing

/// Slice (c) of the main-thread sweep: an agent pane's saved page from the last quit (`AgentPaneLaunchImages`,
/// up to 8 MB per pane) was read from disk and decoded on the main thread as the pane was built at launch. The
/// launch now reads every saved page off the main thread from its start (the app's `main`, before any window);
/// a pane's first frame uses its page when that read has ended, else its loading state, and never waits.
@MainActor @Suite(.serialized)
struct AgentPaneLaunchImageReadTests {
    static let work = BackgroundWork(label: "test.launch-images")

    /// An opaque gray 8x8 image at 2x.
    static func page() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    /// The tag state's page directory, saved at the last quit with the pages of `keys`.
    static func saved(_ keys: [String]) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        await AgentPaneLaunchImages(directory: directory).save(Dictionary(uniqueKeysWithValues: try keys.map { ($0, try page()) }))
        for key in keys {
            try #require(FileManager.default.fileExists(atPath: directory.appending(path: "\(key)@2x.jpg").path), "the quit saved no page")
        }
        return directory
    }

    @Test func theLaunchReadsEverySavedPageOffTheMainThread() async throws {
        let directory = try await Self.saved(["tab_a", "tab_b"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe()
        let images = AgentPaneLaunchImages(directory: directory, reader: probe.reader)
        let read = try #require(images.prefetch(on: Self.work), "the launch read did not start")
        await read.value
        #expect(probe.reads == [false, false], "a saved page was read on the main thread")
        #expect(images.take("tab_a")?.size == NSSize(width: 4, height: 4))
        #expect(images.take("tab_b")?.size == NSSize(width: 4, height: 4))
        #expect(images.take("tab_a") == nil, "a saved page was handed out twice")
        #expect(probe.reads.count == 2, "a pane's ask read the disk again")
    }

    /// The pane's first frame never waits: before the read ends it gets nothing (its loading state, as with no
    /// saved page), and a pane shown after the read gets its page at once.
    @Test func aPaneBeforeTheReadEndsGetsItsLoadingStateAndOneAfterGetsItsPage() async throws {
        let directory = try await Self.saved(["tab_a", "tab_b"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let marks = LaunchMarks()
        let images = AgentPaneLaunchImages(directory: directory, reader: probe.reader)
        let prefetch = images.prefetch(on: Self.work, mark: { marks.record($0) })
        let read = try #require(prefetch, "the launch read did not start")
        let started = await probe.waitForStart()
        #expect(started, "the read never started")
        // The read is held on its lane: a take that waited for it would never return.
        #expect(images.take("tab_a") == nil, "a pane got a page before the read ended")
        #expect(marks.names == ["agent_pane.launch_image_missed"])
        probe.release()
        probe.release()
        await read.value
        #expect(marks.names == ["agent_pane.launch_image_missed", "agent_pane.launch_images_read"])
        #expect(images.take("tab_b") != nil, "a pane shown after the read did not get its saved page")
        #expect(probe.reads == [false, false], "a saved page was read on the main thread")
    }
}

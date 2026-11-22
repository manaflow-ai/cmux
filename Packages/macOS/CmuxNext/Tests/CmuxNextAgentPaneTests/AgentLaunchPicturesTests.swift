import AppKit
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat's launch picture is saved while the app runs (`AgentLaunchPictures`), not only at a clean quit, so a
/// kill or a crash still has one; and a save never drops the picture of a chat on screen that has not painted
/// yet (`AgentPaneLaunchImages.save(_:keeping:)`). Leo 2026-11-22 (ask-bb9c69b84e): the agent pane came back
/// far slower than the terminal on restarts.
@MainActor
struct AgentLaunchPicturesTests {
    private static func image() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "launch-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func names(_ directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// The set stays the chats on screen: a shown chat with no new picture keeps its old one, a chat no longer
    /// shown loses its own, and two saves at once never interleave (the second writes after the first).
    @Test func aSaveKeepsTheShownUnpaintedChatsPictureAndDropsTheRest() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = AgentPaneLaunchImages(directory: directory)
        await images.save(["tab_a": try Self.image(), "tab_b": try Self.image()])
        #expect(Self.names(directory) == ["tab_a@2x.jpg", "tab_b@2x.jpg"])
        let page = try Self.image()
        async let first: Void = images.save(["tab_c": page], keeping: ["tab_a"])
        async let second: Void = images.save(["tab_c": page], keeping: ["tab_a"])
        _ = await (first, second)
        #expect(Self.names(directory) == ["tab_a@2x.jpg", "tab_c@2x.jpg"])
        // A key with a new picture is never "kept" twice: its new file replaces the old.
        await images.save(["tab_a": try Self.image()], keeping: ["tab_a"])
        #expect(Self.names(directory) == ["tab_a@2x.jpg"])
    }

    @Test func theFileNameNamesItsKey() {
        #expect(AgentPaneLaunchImages.key(ofFile: "tab_1f@2x.png") == "tab_1f")
        #expect(AgentPaneLaunchImages.key(ofFile: "tab_1f-m9a@3x.jpg") == "tab_1f-m9a")
    }

    /// A first paint saves once its page settled; requests inside the cooldown run once at its end; after
    /// `stop` (the quit saves for itself) nothing runs.
    @Test func aPaintSavesAfterItSettlesAndTheCooldownFoldsRequests() async throws {
        let clock = ManualClock()
        let (saves, sink) = AsyncStream.makeStream(of: Void.self)
        var count = 0
        let pictures = AgentLaunchPictures(clock: clock) { count += 1; sink.yield() }
        var next = saves.makeAsyncIterator()

        pictures.pagePainted()
        try await clock.waitForSleeper()
        clock.advance(by: AgentLaunchPictures.settle)
        _ = await next.next()
        #expect(count == 1)

        // Inside the cooldown: folded into one save at its end.
        pictures.pagePainted()
        pictures.request(after: .zero)
        try await clock.waitForSleeper()
        clock.advance(by: AgentLaunchPictures.cooldown)
        _ = await next.next()
        #expect(count == 2)

        pictures.stop()
        pictures.request(after: .zero)
        #expect(clock.sleeperCount <= 1) // at most the cooldown of the second save, cancelled by stop
        clock.advance(by: AgentLaunchPictures.cooldown * 2)
        #expect(count == 2)
    }
}

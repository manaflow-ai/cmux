import AppKit
@testable import CmuxNextApps
import CmuxNextSidebar
import Foundation
import Testing

/// `MediaAppOps.card`: the Now Playing card's sources as `media.get` and `media.control` see them.
@MainActor
struct MediaAppOpsCardTests {
    private final class Box: @unchecked Sendable {
        var shown: SidebarNowPlaying?
        var ran: [SidebarNowPlayingCommand] = []
    }

    private static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous", next: "Next")

    /// A 600x400 PNG, as a file's embedded art can be.
    private static func bigArt() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func theCardsTrackIsAnsweredWithItsArtworkRedrawnSmall() async throws {
        let box = Box()
        box.shown = SidebarNowPlaying(title: "Song", artist: "Band", artwork: try Self.bigArt(), isPlaying: false, position: 5,
                                      duration: 60, positionDate: Date(timeIntervalSince1970: 2), canNext: true, labels: Self.labels,
                                      app: .init(bundleIdentifier: "com.apple.Music", name: "Music"))
        let ops = MediaAppOps.card({ box.shown }, perform: { box.ran.append($0) })
        let value = try await ops.handle(AppHostCapabilityRequest(app: "local/x", op: "media.get", params: .object([:]), origin: "script"))
        let track = try #require(value["track"])
        #expect(track["title"] == "Song" && track["source"] == "Music" && track["can_next"] == true && track["position_ms"] == 2_000)
        let url = try #require(track["artwork"]?.stringValue)
        #expect(url.hasPrefix("data:image/png;base64,"))
        let png = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let image = try #require(NSImage(data: png))
        #expect(max(image.size.width, image.size.height) <= CGFloat(MediaAppOps.ArtworkURL.side))
    }

    @Test func aTapRunsOnTheCardAndNothingPlayingRunsNothing() async throws {
        let box = Box()
        let ops = MediaAppOps.card({ box.shown }, perform: { box.ran.append($0) })
        let tap = AppHostCapabilityRequest(app: "local/x", op: "media.control", params: ["command": "seek", "seconds": 12], origin: "user")
        await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(tap) }
        #expect(box.ran.isEmpty)
        box.shown = SidebarNowPlaying(title: "Song", isPlaying: true, labels: Self.labels)
        #expect(try await ops.handle(tap) == .null)
        #expect(box.ran == [.seek(12)])
        let feed = AppProviderChangeFeed.media { box.shown }
        #expect(feed.family == "media")
    }
}

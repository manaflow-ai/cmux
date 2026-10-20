@testable import CmuxNextAgentPane
@testable import CmuxNextNowPlaying
import CmuxNextSettings
import CmuxNextSidebar
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The New Tab page's Now Playing player, host side: the page's controls decode to commands and
/// reach the App's handler (anything else is refused), the track goes to the page as the JSON
/// newtab/nowPlaying.ts reads, and the card's track maps onto it with its artwork as a data URL.
@MainActor @Suite(.serialized) struct NewTabNowPlayingTests {
    static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "nowPlaying.command", "params": params])
    }

    @Test func thePagesControlsDecode() {
        #expect(Self.request(["command": "playPause"]) == .nowPlaying(.playPause))
        #expect(Self.request(["command": "previous"]) == .nowPlaying(.previous))
        #expect(Self.request(["command": "next"]) == .nowPlaying(.next))
        #expect(Self.request(["command": "seek", "seconds": 90.5]) == .nowPlaying(.seek(90.5)))
        for bad: [String: Any] in [[:], ["command": "stop"], ["command": "seek"], ["command": "seek", "seconds": -1]] {
            #expect(Self.request(bad) == .unsupported("nowPlaying.command"), "\(bad) decoded")
        }
        #expect(AgentPageOps.methods["nowPlaying.command"] == "nowPlaying.command", "the page host refuses the op")
    }

    @Test func aControlReachesTheAppOnlyOnceWired() {
        let player = AgentPaneNowPlaying.shared
        let saved = player.onCommand
        defer { player.onCommand = saved }
        player.onCommand = nil
        #expect(!player.perform(.next), "an unwired player took the control")
        var got: [AgentPaneNowPlaying.Command] = []
        player.onCommand = { got.append($0) }
        #expect(player.perform(.playPause) && player.perform(.seek(3)))
        #expect(got == [.playPause, .seek(3)])
        #expect(NewTabNowPlaying.sidebarCommand(.seek(3)) == .seek(3) && NewTabNowPlaying.sidebarCommand(.next) == .next)
    }

    @Test func theTrackGoesToThePageAsItReadsIt() throws {
        let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")
        let shown = SidebarNowPlaying(title: "Weightless", artist: "Marconi Union", artwork: Data([1, 2, 3]), isPlaying: true,
                                      position: 60, duration: 480, rate: 1, positionDate: Date(timeIntervalSince1970: 1_800_000_000),
                                      canPrevious: true, canNext: false, labels: labels)
        let track = NewTabNowPlaying.track(shown, artwork: "data:image/png;base64,AQID")
        let event = AgentPageEvent.nowPlaying(track)
        #expect(event.kind == "nowPlaying")
        guard case .object(let json) = event.value else { Issue.record("not an object: \(event.value)"); return }
        #expect(json["title"] == .string("Weightless") && json["artist"] == .string("Marconi Union"))
        #expect(json["playing"] == .bool(true) && json["canNext"] == .bool(false) && json["canPrevious"] == .bool(true))
        #expect(json["position"] == .number(60) && json["duration"] == .number(480) && json["rate"] == .number(1))
        #expect(json["positionDate"] == .number(1_800_000_000_000))
        #expect(json["artwork"] == .string("data:image/png;base64,AQID"))
        #expect(json["labels"] == .object(["play": .string("Play"), "pause": .string("Pause"),
                                           "previous": .string("Previous Track"), "next": .string("Next Track")]))
        #expect(AgentPageEvent.nowPlaying(nil).value == .null, "nothing playing is not null for the page")
    }

    /// cmux's own player hands over the file's embedded art as is (often a multi-MB JPEG); the page
    /// gets it redrawn as a small PNG, since every track change goes to every agent page.
    @Test func largeArtworkReachesThePageAsASmallPNG() throws {
        let side = 1200
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let url = try #require(NewTabNowPlaying.artworkURL(out as Data))
        let prefix = "data:image/png;base64,"
        #expect(url.hasPrefix(prefix))
        let png = try #require(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == NewTabNowPlaying.artworkSide && image.height == NewTabNowPlaying.artworkSide)
        #expect(NewTabNowPlaying.artworkURL(Data([1, 2, 3])) == nil, "bytes that are not an image became artwork")
    }
}

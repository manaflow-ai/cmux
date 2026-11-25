import CmuxNextApps
import Foundation
import Testing

/// `media.get` and `media.control`: what plays in cmux for an extension's own player, and its transport.
@MainActor
struct MediaAppOpsTests {
    private final class Ran: @unchecked Sendable {
        var commands: [MediaAppOps.Command] = []
    }

    private func request(_ op: String, _ params: AppJSON = .object([:]), origin: String = "user") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/showcase-now-playing", op: op, params: params, origin: origin)
    }

    private let song = MediaAppOps.Track(
        title: "Night Drive", artist: "The Band", artwork: "data:image/png;base64,AAAA", isPlaying: true, position: 42,
        duration: 180, rate: 1, positionDate: Date(timeIntervalSince1970: 1_000), canPrevious: false, canNext: true,
        source: "Music")

    @Test func getAnswersTheTrackInTheSignalsShape() async throws {
        let song = song
        let ops = MediaAppOps(track: { song }, perform: { _ in true })
        #expect(ops.families == ["media"])
        let value = try await ops.handle(request("media.get", origin: "script"))
        #expect(value == ["track": [
            "title": "Night Drive", "artist": "The Band", "artwork": "data:image/png;base64,AAAA", "playing": true,
            "position": 42, "duration": 180, "rate": 1, "position_ms": 1_000_000, "can_previous": false,
            "can_next": true, "source": "Music",
        ]])
    }

    @Test func getAnswersNullWhileNothingPlaysAndLeavesOutAnOversizedArtwork() async throws {
        let silent = MediaAppOps(track: { nil }, perform: { _ in false })
        #expect(try await silent.handle(request("media.get")) == ["track": .null])
        var big = song
        big.artwork = "data:image/png;base64," + String(repeating: "A", count: MediaAppOps.maxArtworkBytes)
        big.position = nil
        let value = try await MediaAppOps(track: { big }, perform: { _ in true }).handle(request("media.get"))
        #expect(value["track"]?["artwork"] == nil)
        #expect(value["track"]?["position"] == nil, "a live stream has no position")
    }

    @Test func aTappedControlRunsOnWhatPlays() async throws {
        let ran = Ran()
        let ops = MediaAppOps(track: { nil }, perform: { ran.commands.append($0); return true })
        for params: AppJSON in [["command": "play_pause"], ["command": "next"], ["command": "previous"], ["command": "seek", "seconds": 30]] {
            #expect(try await ops.handle(request("media.control", params)) == .null)
        }
        #expect(ran.commands == [.playPause, .next, .previous, .seek(30)])
    }

    @Test func aScriptControlABadCommandOrNothingPlayingIsRefused() async {
        let ran = Ran()
        let ops = MediaAppOps(track: { nil }, perform: { ran.commands.append($0); return true })
        await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request("media.control", ["command": "next"], origin: "script")) }
        for params: AppJSON in [["command": "louder"], ["command": "seek"], ["command": "seek", "seconds": -1], .object([:])] {
            await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request("media.control", params)) }
        }
        #expect(ran.commands.isEmpty)
        let silent = MediaAppOps(track: { nil }, perform: { _ in false })
        do {
            _ = try await silent.handle(request("media.control", ["command": "play_pause"]))
            Issue.record("nothing plays: refused")
        } catch {
            #expect(error.code == "media.nothing_playing")
        }
        await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request("media.stop")) }
    }
}

import CmuxNextNowPlaying
import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// The built-in music player (cx-imt2i): cmux plays the person's own files, folders and stream
/// URLs, and the sidebar's Now Playing card shows and drives it. The player wins the card while
/// it plays; a browser tab takes it over only by playing aloud.
@MainActor @Suite(.serialized) struct MusicPlayerTests {
    /// A short silent WAV file at `url`.
    static func writeWAV(_ url: URL, seconds: Double = 2) throws {
        let rate = 8000, samples = Int(Double(rate) * seconds), bytes = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes)); data.append(Data(count: bytes))
        try data.write(to: url)
    }

    /// A fresh folder holding `names` as songs, plus a file that is no song.
    static func folder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-music-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try writeWAV(folder.appendingPathComponent(name)) }
        try Data("not a song".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        return folder
    }

    /// A browser tab's source standing in for the playing tab.
    @Observable final class FakeTab: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var commands: [SidebarNowPlayingCommand] = []
        func perform(_ command: SidebarNowPlayingCommand) { commands.append(command) }
    }

    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous", next: "Next")

    @Test func aFolderPlaysItsSongsInNameOrderAndTheCardDrivesThem() throws {
        let folder = try Self.folder(["2 Tide.wav", "10 Dusk.wav", "1 Dawn.wav"])
        let tracks = MusicPlayer.tracks(from: [folder])
        #expect(tracks.map(\.lastPathComponent) == ["1 Dawn.wav", "2 Tide.wav", "10 Dusk.wav"], "the folder's songs are \(tracks)")
        let player = MusicPlayer(labels: Self.labels)
        defer { player.stop() }
        #expect(player.nowPlaying == nil, "an idle player shows on the card")
        player.play(tracks)
        let first = try #require(player.nowPlaying, "a playing folder is not on the card")
        #expect(first.title == "1 Dawn" && first.isPlaying && first.canNext && first.canPrevious)
        player.perform(.next)
        #expect(player.nowPlaying?.title == "2 Tide", "Next did not move to the second song")
        player.perform(.playPause)
        #expect(player.nowPlaying?.isPlaying == false, "Play/Pause did not pause")
        player.perform(.previous)
        #expect(player.nowPlaying?.title == "1 Dawn", "Previous at a song's start did not go back")
        player.perform(.next)
        player.perform(.next)
        #expect(player.nowPlaying?.title == "10 Dusk" && player.nowPlaying?.canNext == false, "the last song still offers Next")
        player.stop()
        #expect(player.nowPlaying == nil, "a stopped player stays on the card")
    }

    @Test func aStreamPlaysWithoutAScrubber() async throws {
        let player = MusicPlayer(labels: Self.labels)
        defer { player.stop() }
        let stream = try #require(URL(string: "http://127.0.0.1:9/radio/lofi.mp3"))
        #expect(MusicPlayer.tracks(from: [stream]) == [stream], "a stream URL is not a track")
        player.play([stream])
        let shown = try #require(player.nowPlaying, "a stream is not on the card")
        #expect(shown.title == "lofi")
        #expect(!shown.canSeek, "a live stream offers the scrubber")
        // Nothing answers there: the card stops claiming it plays.
        try await PasswordManagerRouteTests.until({ player.nowPlaying?.isPlaying == false }) { "\(String(describing: player.nowPlaying))" }
    }

    @Test func aSongThatCannotPlayIsSkipped() async throws {
        let folder = try Self.folder(["Good.wav"])
        let player = MusicPlayer(labels: Self.labels)
        defer { player.stop() }
        player.play([folder.appendingPathComponent("Moved.wav")] + MusicPlayer.tracks(from: [folder]))
        try await PasswordManagerRouteTests.until({ player.nowPlaying?.title == "Good" }) { "\(String(describing: player.nowPlaying))" }
    }

    @Test func theQueueEndsPausedAndPlayStartsItAgain() async throws {
        let folder = try Self.folder(["A.wav", "B.wav"])
        let player = MusicPlayer(labels: Self.labels)
        defer { player.stop() }
        player.play(MusicPlayer.tracks(from: [folder]))
        player.perform(.next)
        player.perform(.seek(1.9))
        try await PasswordManagerRouteTests.until({ player.nowPlaying?.isPlaying == false }) { "\(String(describing: player.nowPlaying))" }
        #expect(player.nowPlaying?.title == "B", "the queue did not end on its last song")
        player.perform(.playPause)
        #expect(player.nowPlaying?.title == "A" && player.nowPlaying?.isPlaying == true, "Play after the end did not start the queue again")
    }

    @Test func thePlayerHasTheCardWhileItPlaysAndATabOnlyByPlayingAloud() throws {
        let folder = try Self.folder(["Song.wav"])
        let player = MusicPlayer(labels: Self.labels)
        defer { player.stop() }
        let tab = FakeTab()
        let sources = NowPlayingSources(player: player, tabs: tab)
        #expect(sources.nowPlaying == nil)
        tab.nowPlaying = SidebarNowPlaying(title: "Video", isPlaying: true, labels: Self.labels)
        #expect(sources.nowPlaying?.title == "Video", "a playing tab is not on the card")
        player.play(MusicPlayer.tracks(from: [folder]))
        #expect(sources.nowPlaying?.title == "Song", "the playing player does not win the card")
        sources.perform(.playPause)
        #expect(player.nowPlaying?.isPlaying == false && tab.commands.isEmpty, "the card's control did not reach the player")
        #expect(sources.nowPlaying?.title == "Video", "a tab playing aloud does not take over from a paused player")
        sources.perform(.next)
        #expect(tab.commands == [.next], "the card's control did not reach the tab it shows")
        tab.nowPlaying = nil
        #expect(sources.nowPlaying?.title == "Song", "a paused player leaves the card once the tab stops")
    }
}

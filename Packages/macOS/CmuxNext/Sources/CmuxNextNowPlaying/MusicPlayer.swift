public import AVFoundation
import CmuxNextBrowser
public import CmuxNextSidebar
import CmuxNextWakeups
public import Foundation
public import Observation
import UniformTypeIdentifiers
import CmuxNextCompat

/// cmux's own music player (cx-imt2i, a preview feature): the person's songs, folders and stream
/// URLs played with AVFoundation, which ships with macOS, so cmux carries no codec. It is a
/// Now Playing source: the sidebar card shows and drives it, and the media keys reach it while it
/// holds Now Playing (``NowPlayingSources``).
///
/// One `AVPlayer` plays the queue a song at a time, so Previous can go back; a song that ends
/// or cannot play starts the next one, and the last one ends the queue paused on it (Play then
/// starts the queue again). Song titles and artists come from the file's metadata, else its
/// name; a stream shows its file name and no scrubber. The `AVPlayer` exists once something plays.
@Observable
public final class MusicPlayer: NowPlayingSource {
    /// The songs and streams queued, in play order.
    public private(set) var queue: [URL] = []
    /// The one playing (or paused) in `queue`.
    public private(set) var index = 0
    /// Whether the player was asked to play (it may still be loading); false once the song fails.
    private var playing = false
    /// The queue played to its end: Play starts it again.
    private var ended = false
    /// The position read at `positionDate`, the song's length, and its metadata once loaded.
    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var duration: TimeInterval?
    private var details: (url: URL, title: String?, artist: String?, artwork: Data?)?
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private let labels: SidebarNowPlaying.Labels
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservers: [MainActorObservation] = []
    /// Previous restarts the song once it has played this long, as music apps do.
    static let restartAfter: TimeInterval = 3

    /// A player with the browser media controls' titles.
    public convenience init() {
        self.init(labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                                   previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next))
    }

    public init(labels: SidebarNowPlaying.Labels) {
        self.labels = labels
    }

    private var player: AVPlayer {
        if let avPlayer { return avPlayer }
        let player = AVPlayer()
        player.preventsDisplaySleepDuringVideoPlayback = false
        rateObservation = player.observe(\.rate, options: [.new]) { @Sendable [weak self] _, _ in
            // AVFoundation may report from its own threads: inline on main, a hop otherwise.
            MainDelivery().run { self?.readPosition() }
        }
        avPlayer = player
        return player
    }

    /// The songs in `urls`, in play order: a folder's songs by name (as Finder sorts them,
    /// "2" before "10"), including its subfolders'; a file that is not audio is left out; an
    /// http(s) URL is a stream. Reads the disk, so callers run it off the main actor.
    public nonisolated static func tracks(from urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return [url] }
            guard url.isFileURL else { return [] }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
            guard isFolder.boolValue else { return isSong(url) ? [url] : [] }
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL } ?? []
            return files.filter(isSong).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    private nonisolated static func isSong(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }

    /// Plays `tracks` from the first (an empty list stops).
    public func play(_ tracks: [URL]) {
        guard !tracks.isEmpty else { return stop() }
        queue = tracks
        load(0)
    }

    /// Stops and empties the queue: the card leaves.
    public func stop() {
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        unobserveItem()
        ended = false
        queue = []
        index = 0
        playing = false
        position = 0
        duration = nil
        details = nil
    }

    public var nowPlaying: SidebarNowPlaying? {
        guard queue.indices.contains(index) else { return nil }
        let url = queue[index]
        let shown = details?.url == url ? details : nil
        let stream = Self.isStream(url)
        return SidebarNowPlaying(
            title: shown?.title ?? url.deletingPathExtension().lastPathComponent, artist: shown?.artist ?? "",
            artwork: shown?.artwork, isPlaying: playing, position: stream ? nil : position, duration: stream ? nil : duration,
            positionDate: positionDate, canPrevious: true, canNext: index + 1 < queue.count, labels: labels)
    }

    public func perform(_ command: SidebarNowPlayingCommand) {
        guard queue.indices.contains(index) else { return }
        switch command {
        case .playPause: playing ? pause() : resume()
        case .next: if index + 1 < queue.count { load(index + 1) }
        case .previous:
            if index > 0, currentPosition() < Self.restartAfter { load(index - 1) } else { seek(to: 0) }
        case .seek(let seconds): seek(to: seconds)
        // The player plays sound only.
        case .pictureInPicture: break
        }
    }

    /// Plays on from where it is (the start again once the queue ended).
    public func resume() {
        guard queue.indices.contains(index) else { return }
        if ended || player.currentItem == nil { return load(ended ? 0 : index) }
        playing = true
        player.play()
        readPosition()
    }

    public func pause() {
        playing = false
        player.pause()
        readPosition()
    }

    private func load(_ next: Int) {
        unobserveItem()
        ended = false
        index = next
        let url = queue[next]
        let item = AVPlayerItem(url: url)
        if Self.isStream(url) { item.preferredForwardBufferDuration = 2 }
        player.replaceCurrentItem(with: item)
        position = 0
        positionDate = Date()
        duration = nil
        observe(item, url: url)
        playing = true
        player.play()
    }

    private func observe(_ item: AVPlayerItem, url: URL) {
        let id = ObjectIdentifier(item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            let seconds = item.duration.seconds, failed = item.status == .failed
            MainDelivery().run { self?.itemChanged(id, failed: failed, seconds: seconds.isFinite && seconds > 0 ? seconds : nil) }
        }
        let center = NotificationCenter.default
        itemObservers = [
            MainActorObservation(AVPlayerItem.didPlayToEndTimeNotification, object: item, center: center) { [weak self] in
                self?.songEnded(failed: false)
            },
            MainActorObservation(AVPlayerItem.failedToPlayToEndTimeNotification, object: item, center: center) { [weak self] in
                self?.songEnded(failed: true)
            },
        ]
        Task { [weak self] in
            let details = await Self.details(of: item.asset)
            guard let self, self.queue.indices.contains(self.index), self.queue[self.index] == url else { return }
            self.details = (url, details.title, details.artist, details.artwork)
        }
    }

    private func unobserveItem() {
        itemObservation = nil
        itemObservers.removeAll()
    }

    /// The current item's status: its length once ready; a failed one ends as a song does.
    private func itemChanged(_ id: ObjectIdentifier, failed: Bool, seconds: TimeInterval?) {
        guard let item = avPlayer?.currentItem, ObjectIdentifier(item) == id else { return }
        if failed { return songEnded(failed: true) }
        if duration != seconds { duration = seconds }
        readPosition()
    }

    /// The song ended, or could not play: the next one plays, else the queue ends paused.
    private func songEnded(failed: Bool) {
        guard index + 1 < queue.count else {
            playing = false
            ended = !failed || queue.count > 1
            return readPosition()
        }
        load(index + 1)
    }

    private func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        position = max(0, seconds)
        positionDate = Date()
        player.seek(to: target) { [weak self] _ in MainDelivery().run { self?.readPosition() } }
    }

    /// The position now, moved on from the last read while playing.
    private func currentPosition() -> TimeInterval {
        let seconds = avPlayer?.currentTime().seconds ?? position
        return seconds.isFinite ? seconds : position
    }

    /// Takes the player's position as of now, so the card moves on from it.
    private func readPosition() {
        position = currentPosition()
        positionDate = Date()
    }

    private nonisolated static func isStream(_ url: URL) -> Bool { !url.isFileURL }

    /// The song's title, artist and artwork from its metadata, each nil when the file has none.
    private static func details(of asset: AVAsset) async -> (title: String?, artist: String?, artwork: Data?) {
        guard let items = try? await asset.load(.commonMetadata) else { return (nil, nil, nil) }
        func first(_ id: AVMetadataIdentifier) -> AVMetadataItem? {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
        }
        let title: String? = (try? await first(.commonIdentifierTitle)?.load(.stringValue)) ?? nil
        let artist: String? = (try? await first(.commonIdentifierArtist)?.load(.stringValue)) ?? nil
        let artwork: Data? = (try? await first(.commonIdentifierArtwork)?.load(.dataValue)) ?? nil
        return (title?.isEmpty == false ? title : nil, artist?.isEmpty == false ? artist : nil, artwork)
    }
}

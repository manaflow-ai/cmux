public import AVFoundation
public import CmuxHomeCore
import Foundation
import QuartzCore

/// Where a video's original bytes come from for inline playback: a local
/// file or a short-lived signed GET (the render core's `MediaStore`, or a
/// host's own media cache such as the Mac MessagesLab host's `HomeMedia`).
@MainActor
public protocol HomeVideoSource: AnyObject {
    func originalURL(for ref: AttachmentRef) async throws -> URL
}

/// Where a video bubble is: its poster, fetching its bytes, playing, or paused.
public enum HomeVideoState: Sendable, Hashable {
    case poster, loading, playing, paused
}

/// Inline playback by row key. A video plays inside its bubble (an
/// `AVPlayerLayer` under the bubble mask); its URL is fetched only when the
/// user plays it. The URL may be a short-lived signed GET: a resume after
/// `urlLifetime`, a stream failure while playing, or a resume of an item
/// that failed to load, fetches it again through the loader and continues
/// at the same time. A row that scrolls away pauses; the end
/// of the video returns it to the start, paused.
@MainActor
public final class VideoPlayback {
    private struct Entry {
        var state: HomeVideoState
        var ref: AttachmentRef
        var player: AVPlayer?
        var layer: AVPlayerLayer?
        var load: Task<Void, Never>?
        var fetchedAt = Date.distantPast
        var resumeAt: CMTime = .zero
        /// One refetch per fetched URL (a URL that fails again stops).
        var refetched = false
        var observers: [any NSObjectProtocol] = []
        var status: NSKeyValueObservation?
    }

    /// Signed GET URLs live 10 minutes; a resume after 9 refetches first.
    static let urlLifetime: TimeInterval = 9 * 60
    private var entries: [String: Entry] = [:]
    /// A row's playback changed (the scene re-decorates it).
    public var onChange: (String) -> Void = { _ in }
    var now: () -> Date = { Date() }

    public init() {}

    public func state(_ key: String) -> HomeVideoState { entries[key]?.state ?? .poster }

    /// The player layer while there is a player (also while a paused
    /// video fetches its URL again, so the frame stays).
    public func layer(_ key: String) -> AVPlayerLayer? {
        guard let entry = entries[key], entry.state != .poster, entry.player != nil else { return nil }
        return entry.layer
    }

    /// Poster or paused: play. Playing: pause. Loading: cancel.
    public func toggle(_ key: String, ref: AttachmentRef, media: any HomeVideoSource) {
        var entry = entries[key] ?? Entry(state: .poster, ref: ref)
        switch entry.state {
        case .poster:
            entries[key] = entry
            fetch(key, media: media, at: entry.resumeAt)
            return
        case .loading:
            entry.load?.cancel()
            entry.load = nil
            entry.state = entry.player == nil ? .poster : .paused
        case .playing:
            entry.player?.pause()
            entry.state = .paused
        case .paused:
            // An old signed URL, or an item that never loaded (an expired
            // URL fails before it plays): fetch again, same position.
            if now().timeIntervalSince(entry.fetchedAt) > Self.urlLifetime || entry.player?.currentItem?.status == .failed {
                entries[key] = entry
                fetch(key, media: media, at: entry.player?.currentTime() ?? .zero)
                return
            }
            entry.player?.play()
            entry.state = .playing
        }
        entries[key] = entry
        onChange(key)
    }

    /// Fetches the URL (again) and plays from `time`.
    private func fetch(_ key: String, media: any HomeVideoSource, at time: CMTime) {
        guard var entry = entries[key] else { return }
        let ref = entry.ref
        entry.state = .loading
        entry.resumeAt = time
        entry.load?.cancel()
        entry.load = Task { [weak self, weak media] in
            let url = try? await media?.originalURL(for: ref)
            guard let self else { return }
            guard !Task.isCancelled, let media else { self.entries[key]?.load = nil; return }
            self.started(key, url: url, media: media)
        }
        entries[key] = entry
        onChange(key)
    }

    private func started(_ key: String, url: URL?, media: any HomeVideoSource) {
        guard var entry = entries[key], entry.state == .loading else { return }
        entry.load = nil
        guard let url else {
            entry.state = entry.player == nil ? .poster : .paused
            entries[key] = entry
            onChange(key)
            return
        }
        let item = AVPlayerItem(url: url)
        let player = entry.player ?? AVPlayer()
        player.replaceCurrentItem(with: item)
        if entry.layer == nil {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.actions = RowLayer.noActions
            entry.layer = layer
        }
        entry.observers.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        entry.observers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended(key) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self, weak media] _ in
                MainActor.assumeIsolated {
                    guard let media else { return }
                    self?.failed(key, media: media)
                }
            },
        ]
        entry.status = item.observe(\.status) { [weak self, weak media] item, _ in
            let status = item.status
            Task { @MainActor [weak self, weak media] in
                guard let self, let media else { return }
                self.statusChanged(key, status: status, media: media)
            }
        }
        if entry.resumeAt != .zero { player.seek(to: entry.resumeAt) }
        entry.player = player
        entry.fetchedAt = now()
        entry.state = .playing
        entries[key] = entry
        player.play()
        onChange(key)
    }

    /// A URL that loads clears the refetch guard; one that fails (an
    /// expired signed GET) is fetched once more.
    private func statusChanged(_ key: String, status: AVPlayerItem.Status, media: any HomeVideoSource) {
        switch status {
        case .readyToPlay: entries[key]?.refetched = false
        case .failed: failed(key, media: media)
        default: break
        }
    }

    /// The URL expired or the stream broke: fetch once more, same position.
    /// A second failure in a row stops, paused with the play badge.
    private func failed(_ key: String, media: any HomeVideoSource) {
        guard var entry = entries[key], entry.state == .playing || entry.state == .paused else { return }
        guard !entry.refetched else {
            entry.player?.pause()
            entry.state = .paused
            entries[key] = entry
            onChange(key)
            return
        }
        entries[key]?.refetched = true
        fetch(key, media: media, at: entry.player?.currentTime() ?? .zero)
    }

    private func ended(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.player?.seek(to: .zero)
        entry.state = .paused
        entries[key] = entry
        onChange(key)
    }

    /// The row left the viewport: its player is released (memory) and the
    /// position kept; playing again fetches the URL and continues there.
    public func rowLeft(_ key: String) {
        guard var entry = entries[key], entry.player != nil || entry.load != nil else { return }
        entry.load?.cancel()
        entry.load = nil
        if let time = entry.player?.currentTime() { entry.resumeAt = time }
        entry.player?.pause()
        entry.observers.forEach { NotificationCenter.default.removeObserver($0) }
        entry.observers = []
        entry.status = nil
        entry.player = nil
        entry.layer = nil
        entry.state = .poster
        entries[key] = entry
    }

    /// Keys with a player or a fetch in flight (a host re-places their layers).
    public var activeKeys: [String] { entries.filter { $0.value.player != nil || $0.value.load != nil }.map(\.key) }

    /// Returns when no video is fetching its URL.
    public func settled() async {
        while let next = entries.values.compactMap(\.load).first {
            await next.value
        }
    }
}

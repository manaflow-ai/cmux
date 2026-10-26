import AVFoundation
import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO

/// Where attachment bytes come from. The data side (CmuxHomeCore's source
/// fetch) answers with local files; the render core never opens a network
/// connection itself. Both calls must be idempotent and cancel-safe: a row
/// that scrolls away cancels its request.
public protocol HomeAttachmentLoader: Sendable {
    /// A local image file for an image bubble, at most `maxPixel` on its long side.
    func thumbnail(for ref: AttachmentRef, maxPixel: Int) async throws -> URL
    /// A local image file with a video's poster frame. A video without a
    /// poster throws; the bubble then keeps its placeholder and the video's
    /// bytes are never fetched for a frame.
    func poster(for ref: AttachmentRef, maxPixel: Int) async throws -> URL
    /// A URL AVPlayer can play for video playback: a local file or a
    /// short-lived signed GET (with Range). The renderer asks again when a
    /// paused video resumes after 9 minutes or its item failed to load.
    func original(for ref: AttachmentRef) async throws -> URL
}

/// Decoded bubble images by content hash. A miss starts one load (local
/// file, else the loader) and one decode off the main actor; the result
/// reaches the rows through `onImage`. Nothing here changes layout: the
/// rows were sized from the pixel size before any request started.
///
/// The host sizes the cache (`maxBytes`, its ``HomeMemoryBudget`` share)
/// and the scene says which pictures rows on screen show (`show`). Those are
/// never dropped, whatever the budget: their layers hold them anyway, and
/// dropping one would load it again on the next commit. Other pictures go
/// least recently used first when an arrival passes the budget or the host
/// asks (`trim(toBytes:)`); the next ask loads them again (local file
/// first). A draft's preview is the host's own image, kept until its
/// picture arrives, and is not counted.
@MainActor
final class MediaStore: HomeVideoSource { // memory: consumer via HomeRenderMemoryConsumer (CmuxNextHome)
    var loader: (any HomeAttachmentLoader)? {
        didSet {
            failed.removeAll()
            onReload()
        }
    }
    /// A hash's image is ready (the scene puts it on the visible rows).
    var onImage: (String) -> Void = { _ in }
    /// The loader changed: the scene asks again for the visible rows.
    var onReload: () -> Void = {}

    private var images: [String: CGImage] = [:]
    /// When each picture in `images` was last asked for (a counter, not a clock).
    private var lastUse: [String: Int] = [:]
    private var useTick = 0
    /// The pictures rows on screen show: no arrival or trim drops them.
    private var shown: Set<String> = []
    /// Pixel bytes of `images`.
    private(set) var bytes = 0
    /// The most pixel bytes `images` keeps. Lowering it frees nothing: the
    /// next arrival drops the oldest pictures down to it.
    var maxBytes: Int
    private var previews: [String: CGImage] = [:]
    private var locals: [String: (file: URL, poster: URL?)] = [:]
    private var jobs: [String: Job] = [:]
    private var lastJob = 0
    private var failed: Set<String> = []

    private struct Job {
        let id: Int
        let task: Task<Void, Never>
    }

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    /// Cached pictures.
    var count: Int { images.count }

    /// The image for a media bubble; on a miss its load starts and the
    /// host's preview (if any) shows until the full picture arrives.
    func image(for media: MediaPart, maxPixel: Int) -> CGImage? {
        let hash = media.ref.hash
        if let hit = images[hash] {
            useTick += 1
            lastUse[hash] = useTick
            return hit
        }
        let preview = previews[hash]
        guard jobs[hash] == nil, !failed.contains(hash) else { return preview }
        let local = locals[hash]
        guard local != nil || loader != nil else { return preview }
        let loader = self.loader
        let ref = media.ref
        let isVideo = media.isVideo
        lastJob += 1
        let id = lastJob
        // task-owner: kept in `jobs` until it lands; cancelled when the host hides the transcript.
        let task = Task { [weak self] in
            let image = await Self.load(ref, isVideo: isVideo, local: local, loader: loader, maxPixel: maxPixel)
            // A cancelled load no longer owns its hash; a later load of it may.
            guard let self, !Task.isCancelled, self.jobs[hash]?.id == id else { return }
            self.jobs[hash] = nil
            guard let image else { self.failed.insert(hash); return }
            self.store(image, for: hash)
            self.previews[hash] = nil
            self.onImage(hash)
            self.trim(toBytes: self.maxBytes)
        }
        jobs[hash] = Job(id: id, task: task)
        return preview
    }

    /// A draft's own preview (the host decoded it already): shown at once.
    func usePreview(_ image: CGImage, for hash: String) {
        previews[hash] = image
        onImage(hash)
    }

    /// Local files of a send that is still uploading: they win over the loader.
    func useLocalFile(_ file: URL, poster: URL?, for hash: String) {
        if let known = locals[hash], known.file == file, known.poster == poster { return }
        locals[hash] = (file, poster)
        failed.remove(hash)
    }

    func localFiles(for hash: String) -> (file: URL, poster: URL?)? { locals[hash] }

    /// The original bytes of a video (local file first).
    func originalURL(for ref: AttachmentRef) async throws -> URL {
        if let local = locals[ref.hash] { return local.file }
        guard let loader else { throw CancellationError() }
        return try await loader.original(for: ref)
    }

    /// Returns when no load is in flight.
    func settled() async {
        while let next = jobs.values.first {
            await next.task.value
        }
    }

    /// The pictures rows on screen show now: no arrival or trim drops them
    /// until they leave the screen.
    func show(_ hashes: Set<String>) {
        shown = hashes
    }

    /// Drops the least recently used pictures no row on screen shows until
    /// the cache holds at most `target` bytes (or only shown ones are left).
    func trim(toBytes target: Int) {
        guard bytes > target else { return }
        let candidates = images.keys.filter { !shown.contains($0) }.sorted { lastUse[$0, default: 0] < lastUse[$1, default: 0] }
        for hash in candidates {
            guard bytes > target else { return }
            if let old = images.removeValue(forKey: hash) { bytes -= Self.bytes(of: old) }
            lastUse[hash] = nil
        }
    }

    /// The transcript is hidden and its rows show nothing: drops every
    /// picture and every load in flight. The rows ask again when it shows.
    func releaseHidden() {
        shown.removeAll()
        for (_, job) in jobs { job.task.cancel() }
        jobs.removeAll()
        trim(toBytes: 0)
    }

    private func store(_ image: CGImage, for hash: String) {
        if let old = images.updateValue(image, forKey: hash) { bytes -= Self.bytes(of: old) }
        bytes += Self.bytes(of: image)
        useTick += 1
        lastUse[hash] = useTick
    }

    private static func bytes(of image: CGImage) -> Int { image.bytesPerRow * image.height }

    private nonisolated static func load(_ ref: AttachmentRef, isVideo: Bool, local: (file: URL, poster: URL?)?,
                                         loader: (any HomeAttachmentLoader)?, maxPixel: Int) async -> CGImage? {
        if let local {
            let image = if let poster = local.poster {
                await decode(poster, maxPixel: maxPixel)
            } else if isVideo {
                await videoFrame(local.file, maxPixel: maxPixel)
            } else {
                await decode(local.file, maxPixel: maxPixel)
            }
            // A local copy that is gone (cleaned after upload) falls back to the loader.
            if let image { return image }
        }
        guard let loader else { return nil }
        let url = isVideo ? try? await loader.poster(for: ref, maxPixel: maxPixel)
                          : try? await loader.thumbnail(for: ref, maxPixel: maxPixel)
        guard let url else { return nil }
        return await decode(url, maxPixel: maxPixel)
    }

    /// An ImageIO thumbnail with its orientation applied, decoded off the main actor.
    private nonisolated static func decode(_ url: URL, maxPixel: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    /// The first frame of a local video that has no poster file yet.
    private nonisolated static func videoFrame(_ url: URL, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }
}

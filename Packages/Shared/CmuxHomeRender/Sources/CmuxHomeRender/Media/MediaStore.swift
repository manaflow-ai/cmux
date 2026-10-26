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
/// The host sizes the cache (`maxBytes`, its ``HomeMemoryBudget`` share).
/// A picture always reaches its rows before the cache drops anything, so a
/// picture larger than the whole budget still shows and is not loaded again
/// in a loop. Dropping is lossless: rows keep the picture they show, and the
/// next ask loads it again (local file first). A draft's preview is the
/// host's own image, kept until its picture arrives, and is not counted.
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
    /// The hashes of `images`, oldest stored first.
    private var order: [String] = []
    /// Pixel bytes of `images`.
    private(set) var bytes = 0
    /// The most pixel bytes `images` keeps. Lowering it frees nothing: the
    /// next arrival drops the oldest pictures down to it.
    var maxBytes: Int
    private var previews: [String: CGImage] = [:]
    private var locals: [String: (file: URL, poster: URL?)] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    /// Loads whose picture goes to its rows but is not kept (they were in
    /// flight when the host hid the transcript).
    private var showOnly: Set<String> = []
    private var failed: Set<String> = []

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    /// Cached pictures.
    var count: Int { images.count }

    /// The image for a media bubble; on a miss its load starts and the
    /// host's preview (if any) shows until the full picture arrives.
    func image(for media: MediaPart, maxPixel: Int) -> CGImage? {
        let hash = media.ref.hash
        if let hit = images[hash] { return hit }
        let preview = previews[hash]
        guard jobs[hash] == nil, !failed.contains(hash) else { return preview }
        let local = locals[hash]
        guard local != nil || loader != nil else { return preview }
        let loader = self.loader
        let ref = media.ref
        let isVideo = media.isVideo
        jobs[hash] = Task { [weak self] in
            let image = await Self.load(ref, isVideo: isVideo, local: local, loader: loader, maxPixel: maxPixel)
            guard let self else { return }
            self.jobs[hash] = nil
            let keep = self.showOnly.remove(hash) == nil
            guard !Task.isCancelled else { return }
            guard let image else { self.failed.insert(hash); return }
            self.store(image, for: hash)
            self.previews[hash] = nil
            self.onImage(hash)
            // Only after the rows have it: dropping it first would ask for it again.
            if keep { self.trim(toBytes: self.maxBytes) } else { self.forget(hash) }
        }
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
            await next.value
        }
    }

    /// Drops the oldest pictures until the cache holds at most `target` bytes.
    func trim(toBytes target: Int) {
        var n = 0
        while n < order.count, bytes > target {
            if let hash = order[checked: n], let old = images.removeValue(forKey: hash) { bytes -= Self.bytes(of: old) }
            n += 1
        }
        order.removeFirst(n)
    }

    /// The transcript is hidden: drops every picture; loads in flight still
    /// reach their rows but are not kept.
    func releaseHidden() {
        trim(toBytes: 0)
        showOnly.formUnion(jobs.keys)
    }

    private func forget(_ hash: String) {
        guard let old = images.removeValue(forKey: hash) else { return }
        bytes -= Self.bytes(of: old)
        order.removeAll { $0 == hash }
    }

    private func store(_ image: CGImage, for hash: String) {
        if let old = images.updateValue(image, forKey: hash) {
            bytes -= Self.bytes(of: old)
        } else {
            order.append(hash)
        }
        bytes += Self.bytes(of: image)
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

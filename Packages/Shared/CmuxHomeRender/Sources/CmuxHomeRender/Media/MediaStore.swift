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
@MainActor
final class MediaStore {
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
    private var order: [String] = []
    private var previews: [String: CGImage] = [:]
    private var locals: [String: (file: URL, poster: URL?)] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var failed: Set<String> = []
    static let capacity = 120

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
            guard !Task.isCancelled else { return }
            guard let image else { self.failed.insert(hash); return }
            self.store(image, for: hash)
            self.previews[hash] = nil
            self.onImage(hash)
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

    private func store(_ image: CGImage, for hash: String) {
        if images.updateValue(image, forKey: hash) == nil { order.append(hash) }
        while order.count > Self.capacity {
            images[order.removeFirst()] = nil
        }
    }

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

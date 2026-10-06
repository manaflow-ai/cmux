import AVFoundation
import CmuxHomeCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bubble pictures for HomeStore attachment parts, in the form MessagesLab's
/// row drawing reads them (`Images.load` of a `file:` asset): one small,
/// oriented image file per content hash. A photo's picture is its
/// thumbnail, a video's its poster frame; a file part has none. Local files
/// win (my sends: the prepared copy and poster); otherwise the bytes come
/// from the store (`HomeStoreBinding.fetchAttachment`, lane 16's variants:
/// `.thumbnail` for images, `.poster` for video, never the video itself).
/// Nothing here changes layout: rows are sized from the part's pixel size
/// before any picture arrives, and the picture is at least the bubble's
/// pixel width so `Sizing` keeps that size.
@MainActor
final class HomeMedia {
    typealias Fetch = @Sendable (AttachmentRef, AttachmentVariant) async throws -> URL

    /// Where the pictures are written (one folder per process).
    static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-home-media-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    var fetch: Fetch?
    /// A hash's picture is ready (the projection updates the rows showing it).
    var onReady: (String) -> Void = { _ in }

    private var ready: [String: String] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var failed: Set<String> = []
    private var locals: [String: LocalAttachmentFiles] = [:]

    /// The `file:` asset of a hash's picture, nil until it is ready.
    func asset(_ hash: String) -> String? { ready[hash] }

    /// Local files of my own attachment (a draft or a send in flight).
    func useLocal(_ files: LocalAttachmentFiles, for hash: String) {
        guard locals[hash] != files else { return }
        locals[hash] = files
        failed.remove(hash)
    }

    /// Makes the picture of a draft attachment before it enters the field,
    /// so the send's bubble has it from the first frame.
    func prepare(_ attachment: LocalAttachment) async {
        useLocal(attachment.files, for: attachment.ref.hash)
        request(attachment.ref)
        await jobs[attachment.ref.hash]?.value
    }

    /// Starts loading a part's picture once (no-op when ready, loading,
    /// failed, or when the part has no picture).
    func request(_ ref: AttachmentRef) {
        let hash = ref.hash
        guard ready[hash] == nil, jobs[hash] == nil, !failed.contains(hash) else { return }
        let kind = HomeMapping.kind(of: ref)
        guard kind == "image" || kind == "video" else { return }
        let local = locals[hash]
        let fetch = self.fetch
        guard local != nil || fetch != nil else { return }
        let maxPixel = Self.maxPixel(ref)
        let target = Self.directory.appendingPathComponent(hash.replacingOccurrences(of: "/", with: "_"))
        jobs[hash] = Task { [weak self] in
            let file = await Self.load(ref, isVideo: kind == "video", local: local, fetch: fetch, maxPixel: maxPixel, to: target)
            guard let self else { return }
            self.jobs[hash] = nil
            guard let file else { self.failed.insert(hash); return }
            self.ready[hash] = file.absoluteString
            self.onReady(hash)
        }
    }

    /// The original bytes (a click opens them): the local copy, else the store's.
    func original(_ ref: AttachmentRef) async throws -> URL {
        if let local = locals[ref.hash], FileManager.default.fileExists(atPath: local.fileURL.path) { return local.fileURL }
        guard let fetch else { throw CancellationError() }
        return try await fetch(ref, .original)
    }

    /// Returns when no picture is loading (tests).
    func settled() async {
        while let next = jobs.values.first { await next.value }
    }

    /// The long side, in pixels, so the picture's width is at least the
    /// widest bubble (300 pt at 2x): MessagesLab never draws a bubble wider
    /// than its source allows, and a narrower picture would reflow the row.
    nonisolated static func maxPixel(_ ref: AttachmentRef) -> Int {
        guard let w = ref.width, let h = ref.height, w > 0, h > 0 else { return 1024 }
        let long = max(w, h)
        return min(long, max(1024, Int((600.0 * Double(long) / Double(w)).rounded(.up))))
    }

    private nonisolated static func load(_ ref: AttachmentRef, isVideo: Bool, local: LocalAttachmentFiles?, fetch: Fetch?,
                                         maxPixel: Int, to target: URL) async -> URL? {
        if let local {
            let image: CGImage? = if let poster = local.posterURL {
                await decode(poster, maxPixel: maxPixel)
            } else if isVideo {
                await videoFrame(local.fileURL, maxPixel: maxPixel)
            } else {
                await decode(local.fileURL, maxPixel: maxPixel)
            }
            if let image { return await write(image, to: target) }
        }
        guard let fetch else { return nil }
        let url = isVideo ? try? await fetch(ref, .poster) : try? await fetch(ref, .thumbnail(maxPixel: maxPixel))
        guard let url, let image = await decode(url, maxPixel: maxPixel) else { return nil }
        return await write(image, to: target)
    }

    /// An ImageIO thumbnail with its orientation applied, off the main actor.
    private nonisolated static func decode(_ url: URL, maxPixel: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private nonisolated static func videoFrame(_ url: URL, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }

    /// JPEG for opaque pictures, PNG when they have alpha.
    private nonisolated static func write(_ image: CGImage, to target: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let alpha: Bool = switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: false
            default: true
            }
            let url = target.appendingPathExtension(alpha ? "png" : "jpg")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? url : nil
        }.value
    }
}

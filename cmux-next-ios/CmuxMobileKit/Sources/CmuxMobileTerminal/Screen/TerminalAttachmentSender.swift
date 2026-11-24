#if os(iOS)
import AVFoundation
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the composer hands an attachment the moment it is picked: the
/// upload starts then, not on Send, and every stage can be cancelled
/// (design/attachment-upload.md).
@MainActor
public protocol TerminalAttachmentSending: AnyObject {
    /// Starts sending the attachment; nil when there is no Mac to send it to.
    func start(_ attachment: ComposerAttachment) -> String?
    /// Stops it at any stage, at once.
    func cancel(_ uploadID: String)
    /// The file's path on the Mac once it is there whole.
    func wait(_ uploadID: String) async throws -> String
    /// Its newest progress (observable: a view reading it redraws on each ack).
    func progress(_ uploadID: String) -> UploadProgress?
}

/// The live sender: the Rust engine (`AttachmentUploadClient`) for the bytes,
/// the platform encoder for a big video or photo, which Rust's `videoPlan` and
/// `imagePlan` decide.
@MainActor
public final class EngineAttachmentSender: TerminalAttachmentSending {
    private let client: AttachmentUploadClient
    private let destination: @MainActor () -> AttachmentDestination?
    /// Re-encodes in flight, by upload id: cancel stops them.
    private var exports: [String: Task<Void, Never>] = [:]

    public init(client: AttachmentUploadClient = .shared, destination: @escaping @MainActor () -> AttachmentDestination?) {
        self.client = client
        self.destination = destination
    }

    public func start(_ attachment: ComposerAttachment) -> String? {
        guard let destination = destination() else { return nil }
        if attachment.kind == .image, let source = ImageCompressor.Source(attachment) {
            return startImage(source, name: attachment.name, to: destination)
        }
        if let data = attachment.data { return client.start(data, name: attachment.name, to: destination) }
        guard let url = attachment.fileURL else { return nil }
        guard attachment.kind == .video else { return client.start(url, name: attachment.name, to: destination) }
        let id = client.reserve(name: attachment.name, to: destination)
        exports[id] = Task { [weak self] in
            let prepared = await VideoCompressor.prepare(url) { fraction in
                self?.client.compressProgress(id, fraction: fraction)
            }
            guard let self, !Task.isCancelled else {
                if let output = prepared.output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
                return
            }
            self.exports[id] = nil
            if let output = prepared.output {
                self.client.fileReady(id, url: output, ownsFile: true)
            } else {
                self.client.fileReady(id, url: url)
            }
        }
        return id
    }

    /// An image: reserved at once (stage `compressing`), then Rust's `imagePlan` decides
    /// between the original and a JPEG of at most 2048 px, which ImageIO makes off the main
    /// actor. Any failure sends the original under its own name.
    private func startImage(_ source: ImageCompressor.Source, name: String, to destination: AttachmentDestination) -> String {
        let id = client.reserve(name: name, to: destination)
        exports[id] = Task { [weak self] in
            let output = await ImageCompressor.prepare(source)
            guard let self, !Task.isCancelled else {
                if let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
                return
            }
            self.exports[id] = nil
            self.client.compressProgress(id, fraction: 1)
            if let output {
                self.client.fileReady(id, url: output, name: ImageCompressor.jpegName(name), ownsFile: true)
            } else {
                switch source {
                case .data(let data): self.client.fileReady(id, data: data, name: name)
                case .file(let url): self.client.fileReady(id, url: url)
                }
            }
        }
        return id
    }

    public func cancel(_ uploadID: String) {
        exports.removeValue(forKey: uploadID)?.cancel()
        client.cancel(uploadID)
    }

    public func wait(_ uploadID: String) async throws -> String {
        try await client.wait(uploadID)
    }

    public func progress(_ uploadID: String) -> UploadProgress? {
        client.progress[uploadID]
    }
}

/// Runs the downscale Rust's `imagePlan` asks for (JPEG, long side at most
/// 2048) with ImageIO: `CGImageSourceCreateThumbnailAtIndex` decodes straight to
/// the target size (it never holds a 12 MP bitmap), applying the EXIF
/// orientation, and `CGImageDestination` writes the JPEG without the
/// original's metadata. Nil: send the original.
enum ImageCompressor {
    enum Source: Sendable {
        case data(Data)
        case file(URL)

        init?(_ attachment: ComposerAttachment) {
            if let data = attachment.data {
                self = .data(data)
            } else if let url = attachment.fileURL {
                self = .file(url)
            } else {
                return nil
            }
        }
    }

    static func prepare(_ source: Source) async -> URL? {
        await Task.detached(priority: .userInitiated) { encode(source) }.value
    }

    /// `IMG_0001.HEIC` -> `IMG_0001.jpg`.
    static func jpegName(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? "image" : stem) + ".jpg"
    }

    nonisolated static func encode(_ source: Source) -> URL? {
        switch source {
        case .data(let data):
            return encode(CGImageSourceCreateWithData(data as CFData, nil), bytes: data.count)
        case .file(let url):
            // A Files pick is readable only inside its security scope.
            return ScopedFile(url).withAccess { url in
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return encode(CGImageSourceCreateWithURL(url as CFURL, nil), bytes: bytes)
            }
        }
    }

    nonisolated static func encode(_ image: CGImageSource?, bytes: Int) -> URL? {
        guard let image, let plan = plan(for: image, bytes: bytes), plan.reencode else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(plan.maxLongSide),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-encode", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = folder.appendingPathComponent("image.jpg")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: plan.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return output
    }

    /// The image's facts, for Rust to decide on.
    nonisolated static func plan(for image: CGImageSource, bytes: Int) -> ImagePlan? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let format = (CGImageSourceGetType(image) as String?).flatMap { UTType($0)?.preferredFilenameExtension } ?? "image"
        return imagePlan(width: UInt32(clamping: width), height: UInt32(clamping: height), bytes: UInt64(max(0, bytes)), format: format)
    }
}

/// Runs the re-encode Rust's `videoPlan` asks for (HEVC, long side at most
/// 1920) with `AVAssetExportSession`. Any failure sends the original: a
/// bigger upload beats none.
enum VideoCompressor {
    struct Prepared {
        /// The re-encoded file (in its own folder, which the caller removes), or nil: send the original.
        var output: URL?
        var plan: VideoPlan?
    }

    static func prepare(_ source: URL, progress: @escaping @MainActor (Double) -> Void) async -> Prepared {
        let asset = AVURLAsset(url: source)
        guard let plan = await plan(for: asset, at: source), plan.reencode else { return Prepared(output: nil, plan: nil) }
        guard let session = AVAssetExportSession(asset: asset, presetName: plan.preset) else { return Prepared(output: nil, plan: plan) }
        let type: AVFileType = source.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-encode", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return Prepared(output: nil, plan: plan)
        }
        let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(type == .mp4 ? "mp4" : "mov")
        session.shouldOptimizeForNetworkUse = true
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let fraction) = state { await progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            // Cancelling the calling task cancels the export (`export(to:as:)` honors it).
            try await session.export(to: output, as: type)
            return Prepared(output: output, plan: plan)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return Prepared(output: nil, plan: plan)
        }
    }

    /// The asset's facts, for Rust to decide on.
    static func plan(for asset: AVURLAsset, at url: URL) async -> VideoPlan? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, formats) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let shown = size.applying(transform)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC ? "hevc" : "h264" } ?? "unknown"
        return videoPlan(
            width: UInt32(abs(shown.width).rounded()),
            height: UInt32(abs(shown.height).rounded()),
            durationMs: UInt64(max(0, duration.seconds * 1000)),
            bytes: UInt64(max(0, bytes)),
            codec: codec
        )
    }
}
#endif

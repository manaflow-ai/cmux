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
public protocol TerminalAttachmentSending: AnyObject, Sendable {
    /// Starts sending the attachment; nil when there is no Mac to send it to.
    func start(_ attachment: ComposerAttachment) -> String?
    /// Stops it at any stage, at once.
    func cancel(_ uploadID: String)
    /// The file's path on the Mac once it is there whole.
    func wait(_ uploadID: String) async throws -> String
    /// Its newest progress (observable: a view reading it redraws on each ack).
    func progress(_ uploadID: String) -> UploadProgress?
    /// Releases a finished or removed upload's retained state.
    func forget(_ uploadID: String)
    var uploadDestination: AttachmentDestination? { get }
}

public extension TerminalAttachmentSending {
    func forget(_ uploadID: String) {}
    var uploadDestination: AttachmentDestination? { nil }
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
        exports[id] = Task { [weak self, pickedMovie = attachment.pickedMovie] in
            defer { withExtendedLifetime(pickedMovie) {} }
            let prepared = await VideoCompressor.prepare(ScopedFile(url)) { fraction in
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
    /// between the original and an image of at most 2048 px, which ImageIO makes off the main
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
                self.client.fileReady(id, url: output, name: ImageCompressor.encodedName(name, extension: output.pathExtension), ownsFile: true)
            } else {
                switch source {
                case .data(let data): self.client.fileReady(id, data: data, name: name)
                case .file(let url): self.client.fileReady(id, url: url)
                }
            }
        }
        return id
    }

    public var uploadDestination: AttachmentDestination? { destination() }

    public func forget(_ uploadID: String) {
        exports.removeValue(forKey: uploadID)?.cancel()
        client.forget(uploadID)
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

/// Runs the downscale Rust's `imagePlan` asks for (long side at most
/// 2048) with ImageIO: `CGImageSourceCreateThumbnailAtIndex` decodes straight to
/// the target size (it never holds a 12 MP bitmap), applying the EXIF
/// orientation, and `CGImageDestination` writes JPEG or alpha-preserving PNG without
/// the original's metadata. Multi-frame formats keep their original bytes.
/// Nil: send the original.
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

    // ImageIO is synchronous. Run it off the main actor in the upload task so Stop's
    // cancellation is visible between decode, thumbnail creation and JPEG finalization.
    @concurrent
    static func prepare(_ source: Source) async -> URL? {
        encode(source)
    }

    /// `IMG_0001.HEIC` -> `IMG_0001.jpg`.
    static func jpegName(_ name: String) -> String {
        encodedName(name, extension: "jpg")
    }

    static func encodedName(_ name: String, extension ext: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? "image" : stem) + "." + ext
    }

    nonisolated static func encode(_ source: Source) -> URL? {
        guard !Task.isCancelled else { return nil }
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

    nonisolated static func encode(
        _ image: CGImageSource?, bytes: Int,
        outputRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-encode", isDirectory: true)
    ) -> URL? {
        guard !Task.isCancelled, bytes > 0, let image, let plan = plan(for: image, bytes: bytes), plan.reencode else { return nil }
        // Preserve all animation frames and document pages. Like AttachmentImageEncoder,
        // HEIF bursts use their primary image rather than representing an animation.
        let typeName = CGImageSourceGetType(image) as String?
        let isHEIF = typeName == UTType.heic.identifier || typeName == UTType.heif.identifier
        guard CGImageSourceGetCount(image) == 1 || isHEIF else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(plan.maxLongSide),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary), !Task.isCancelled else { return nil }
        let hasAlpha: Bool
        switch scaled.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        let outputType = hasAlpha ? UTType.png : UTType.jpeg
        let folder = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = folder.appendingPathComponent(hasAlpha ? "image.png" : "image.jpg")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        var keepOutput = false
        defer {
            if !keepOutput { try? FileManager.default.removeItem(at: folder) }
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: plan.quality]
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        guard !Task.isCancelled, CGImageDestinationFinalize(destination), !Task.isCancelled,
              AttachmentEncoding.isSmaller(output, than: bytes) else { return nil }
        keepOutput = true
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

enum AttachmentEncoding {
    nonisolated static func isSmaller(_ output: URL, than originalBytes: Int) -> Bool {
        guard let bytes = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return bytes > 0 && bytes < originalBytes
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

    static func prepare(_ file: ScopedFile, progress: @escaping @MainActor (Double) -> Void) async -> Prepared {
        // The picker closes its own scope after adding the tile. AVFoundation reads
        // the source lazily, through the end of export.
        let access = file.open()
        defer { access.close() }
        let source = access.url
        let asset = AVURLAsset(url: source)
        guard !Task.isCancelled,
              let bytes = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0,
              let plan = await plan(for: asset, bytes: bytes)
        else { return Prepared(output: nil, plan: nil) }
        guard !Task.isCancelled, plan.reencode else { return Prepared(output: nil, plan: plan) }
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
        // The session is not Sendable; the watcher only reads its states, which
        // AVFoundation publishes for exactly this concurrent observation.
        nonisolated(unsafe) let observed = session
        let watcher = Task {
            for await state in observed.states(updateInterval: 0.25) {
                if case .exporting(let fraction) = state { await progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            // Cancelling the calling task cancels the export (`export(to:as:)` honors it).
            try await session.export(to: output, as: type)
            if !Task.isCancelled, AttachmentEncoding.isSmaller(output, than: bytes) {
                return Prepared(output: output, plan: plan)
            }
        } catch {
            // A failed or cancelled export may have written a partial movie.
        }
        try? FileManager.default.removeItem(at: folder)
        return Prepared(output: nil, plan: plan)
    }

    /// The asset's facts, for Rust to decide on.
    private static func plan(for asset: AVURLAsset, bytes: Int) async -> VideoPlan? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, formats) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC ? "hevc" : "h264" } ?? "unknown"
        return plan(displaySize: size.applying(transform), duration: duration, bytes: bytes, codec: codec)
    }

    static func plan(displaySize: CGSize, duration: CMTime, bytes: Int, codec: String) -> VideoPlan? {
        // AVFoundation may report indefinite time or nonrepresentable transformed dimensions.
        // Failable conversion also handles a finite Double rounded up to 2^64.
        let milliseconds = duration.seconds * 1000
        guard milliseconds.isFinite, milliseconds >= 0,
              let durationMs = UInt64(exactly: milliseconds.rounded(.towardZero)),
              let width = UInt32(exactly: abs(displaySize.width).rounded()), width > 0,
              let height = UInt32(exactly: abs(displaySize.height).rounded()), height > 0,
              let byteCount = UInt64(exactly: bytes)
        else { return nil }
        return videoPlan(width: width, height: height, durationMs: durationMs, bytes: byteCount, codec: codec)
    }
}
#endif

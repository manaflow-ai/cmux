#if os(iOS)
import AVFoundation
import CmuxMobileLinkFFI
import CmuxMobileTransport
import Foundation

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
/// the platform encoder for a big video, which Rust's `videoPlan` decides.
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

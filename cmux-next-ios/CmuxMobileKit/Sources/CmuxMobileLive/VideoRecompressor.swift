import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import OSLog
#if os(iOS)
import AVFoundation
import CmuxMobileLinkFFI
#endif

/// A picked video, shrunk to HEVC 1920x1080 before it goes to the Mac when the "Shrink videos
/// before sending" setting is on (off by default). Leo, 2026-11-24: "the size needs to be
/// optimized too".
///
/// It runs inside the file's upload (``AcpmuxSessionSource/upload(_:name:cwd:link:macName:)``),
/// which starts when the video is picked (``AttachmentPrestager``), so the export begins at pick.
/// Removing the video or stopping the send cancels the upload's task, and that cancels the
/// export. Whether to export, and whether the export is sent, are Rust's
/// (`video_recompress_plan`, `video_recompress_keep`); this file only runs AVFoundation.
enum VideoRecompressor {
    /// `CmuxMobileModel.SettingsStore.recompressVideos` writes this key.
    static let settingKey = "cmuxMobile.settings.recompressVideos"
    static let log = Logger(subsystem: "dev.cmux.mobile", category: "upload")

    static var enabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// The payload and name to upload for `payload`: the export when the policy says so and
    /// it came out clearly smaller, else the original unchanged. Throws only on cancellation.
    /// `report` hears the export's progress, 0 to 1, from its start to its end (1 also when the
    /// export failed or was not kept); `exported` says an export ran, so the send's bar goes on
    /// from the export's share (Rust's `video_send_fraction`).
    static func prepared(_ payload: LinkUpload.Payload, name: String, report: (@Sendable (Double) async -> Void)? = nil)
        async throws -> (payload: LinkUpload.Payload, name: String, exported: Bool) {
        #if os(iOS)
        guard case .file(let url) = payload, AgentVideo.isVideoName(name) else { return (payload, name, false) }
        let enabled = Self.enabled
        guard enabled else { return (payload, name, false) }
        let access = ScopedFile(url).open()
        defer { access.close() }
        let started = ContinuousClock.now
        let asset = AVURLAsset(url: url)
        let bytes = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        var source = VideoSource(width: 0, height: 0, durationMs: 0, bytes: bytes)
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let size = loaded.0.applying(loaded.1)
            source = VideoSource(width: UInt32(abs(size.width).rounded()), height: UInt32(abs(size.height).rounded()),
                                 durationMs: UInt64((duration.seconds * 1000).rounded()), bytes: bytes)
        }
        let plan = videoRecompressPlan(enabled: enabled, source: source)
        guard plan.recompress else {
            log.info("recompress skip reason=\(String(describing: plan.reason)) bytes=\(bytes)")
            return (payload, name, false)
        }
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            log.info("recompress skip reason=noSession bytes=\(bytes)")
            return (payload, name, false)
        }
        session.shouldOptimizeForNetworkUse = true
        let stem = (name as NSString).deletingPathExtension
        let outName = "\(stem.isEmpty ? "video" : stem).mov"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-recompressed-videos", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let out = folder.appendingPathComponent(outName)
        await report?(0)
        // The export's progress, a quarter second apart, to the pending bubble's bar.
        // The task reads only the states stream, made here (AVFoundation's observation API, meant to
        // be read beside the running export); the session itself never crosses into it.
        let states = ExportStates(stream: session.states(updateInterval: 0.25))
        let watcher = report.map { report in
            Task {
                for await state in states.stream {
                    if case .exporting(let progress) = state { await report(progress.fractionCompleted) }
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Cancelling the calling task cancels the export (`export(to:as:)` honours it).
            try await session.export(to: out, as: .mov)
            watcher?.cancel()
        } catch {
            watcher?.cancel()
            try? FileManager.default.removeItem(at: folder)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.info("recompress failed ms=\(AttachmentPrestager.ms(ContinuousClock.now - started)) bytes=\(bytes) error=\(String(describing: error))")
            await report?(1)
            return (payload, name, true)
        }
        await report?(1)
        let outBytes = UInt64((try? out.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let ms = AttachmentPrestager.ms(ContinuousClock.now - started)
        guard videoRecompressKeep(sourceBytes: bytes, outputBytes: outBytes) else {
            log.info("recompress kept_original ms=\(ms) bytes=\(bytes) out_bytes=\(outBytes)")
            try? FileManager.default.removeItem(at: folder)
            return (payload, name, true)
        }
        log.info("recompress ok ms=\(ms) bytes=\(bytes) out_bytes=\(outBytes) reason=\(String(describing: plan.reason))")
        return (.file(out), outName, true)
        #else
        return (payload, name, false)
        #endif
    }
}

#if os(iOS)
/// The export's states stream, handed to the task that forwards its progress.
private struct ExportStates<Stream: AsyncSequence>: @unchecked Sendable where Stream.Element == AVAssetExportSession.State, Stream.Failure == Never {
    let stream: Stream
}
#endif

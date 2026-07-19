import AppKit
import Foundation
import WebKit

/// Streams browser/agent panes to subscribed guests as pixel frames (share
/// binary kind 0x02): H.264 Annex B primary, JPEG stills fallback.
///
/// One capture loop per subscribed pane, paced with a cancellable
/// `ContinuousClock` sleep at up to ~10 fps (media pacing, not a
/// synchronization substitute). Frames whose 32x32 downsample digest is
/// unchanged are skipped before encoding. A detached or unsnapshottable
/// webview pauses the stream (the viewer keeps its last frame); webviews are
/// never kept alive just for guests.
@MainActor
final class SharePixelStreamer {
    var sendBinary: ((Data) -> Void)?
    /// Resolves a subscribed pane to its live webview (nil pauses the stream).
    var resolveWebView: ((_ ws: String, _ pane: String) -> WKWebView?)?

    @MainActor
    private final class PaneStream {
        let ws: String
        let pane: String
        var count: Int
        var task: Task<Void, Never>?
        let encoder = ShareH264Encoder()
        var lastDigest: UInt64?
        var needsKeyframe = true
        var useStillFallback = false

        init(ws: String, pane: String, count: Int) {
            self.ws = ws
            self.pane = pane
            self.count = count
        }
    }

    private var streamsByPane: [String: PaneStream] = [:]
    /// Insertion order for the concurrency budget (oldest evicted first).
    private var paneOrder: [String] = []
    private static let maxConcurrentPanes = 4
    private static let maxSnapshotWidth: CGFloat = 1280
    private static let videoInterval: Duration = .milliseconds(100)
    private static let stillInterval: Duration = .milliseconds(333)

    func setSubscriberCount(ws: String, pane: String, count: Int) {
        if count <= 0 {
            removeStream(pane: pane)
            return
        }
        if let stream = streamsByPane[pane] {
            if count > stream.count {
                stream.needsKeyframe = true
            }
            stream.count = count
            return
        }
        if paneOrder.count >= Self.maxConcurrentPanes, let oldest = paneOrder.first {
            #if DEBUG
            cmuxDebugLog("share.pixel budget exceeded; evicting pane=\(oldest.prefix(8)) for \(pane.prefix(8))")
            #endif
            removeStream(pane: oldest)
        }
        let stream = PaneStream(ws: ws, pane: pane, count: count)
        streamsByPane[pane] = stream
        paneOrder.append(pane)
        startLoop(for: stream)
    }

    /// Forces a keyframe on every stream (post-`resync`).
    func requestKeyframes() {
        for stream in streamsByPane.values {
            stream.needsKeyframe = true
            stream.lastDigest = nil
        }
    }

    func stopAll() {
        for pane in paneOrder {
            streamsByPane[pane]?.task?.cancel()
            streamsByPane[pane]?.encoder.invalidate()
        }
        streamsByPane.removeAll()
        paneOrder.removeAll()
    }

    private func removeStream(pane: String) {
        guard let stream = streamsByPane.removeValue(forKey: pane) else { return }
        paneOrder.removeAll { $0 == pane }
        stream.task?.cancel()
        stream.encoder.invalidate()
    }

    private func startLoop(for stream: PaneStream) {
        stream.task = Task { @MainActor [weak self, weak stream] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self, let stream else { return }
                let interval = stream.useStillFallback ? Self.stillInterval : Self.videoInterval
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.captureAndSend(stream: stream)
            }
        }
    }

    private func captureAndSend(stream: PaneStream) async {
        guard streamsByPane[stream.pane] === stream,
              let webView = resolveWebView?(stream.ws, stream.pane),
              webView.window != nil,
              webView.bounds.width >= 8,
              webView.bounds.height >= 8 else {
            // Unsnapshottable right now: pause (viewer keeps its last frame)
            // and force a keyframe on resume so late decoders can re-sync.
            stream.needsKeyframe = true
            return
        }
        guard let image = await snapshotImage(of: webView) else {
            stream.needsKeyframe = true
            return
        }
        guard streamsByPane[stream.pane] === stream else { return }

        let digest = SharePixelStillEncoder.changeDigest(of: image)
        if let digest, digest == stream.lastDigest, !stream.needsKeyframe {
            return
        }

        var encoded: SharePixelEncodedFrame?
        if !stream.useStillFallback {
            if let pixelBuffer = SharePixelStillEncoder.pixelBuffer(from: image) {
                encoded = await stream.encoder.encode(
                    pixelBuffer: pixelBuffer,
                    forceKeyframe: stream.needsKeyframe
                )
            }
            if encoded == nil {
                // Encoder unavailable or failed: fall back to stills at ~3 fps.
                #if DEBUG
                cmuxDebugLog("share.pixel h264 failed; falling back to stills pane=\(stream.pane.prefix(8))")
                #endif
                stream.useStillFallback = true
                stream.encoder.invalidate()
            }
        }
        if stream.useStillFallback {
            encoded = SharePixelStillEncoder.encodeJPEG(image)
        }
        guard streamsByPane[stream.pane] === stream, let encoded else { return }

        stream.lastDigest = digest
        if stream.needsKeyframe, encoded.isKeyframe {
            stream.needsKeyframe = false
        }
        guard let binary = ShareBinaryFrame.encode(
            kind: ShareProtocolConstants.binaryKindPixel,
            ws: stream.ws,
            pane: stream.pane,
            payload: encoded.payload
        ) else { return }
        sendBinary?(binary)
    }

    private func snapshotImage(of webView: WKWebView) async -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        if webView.bounds.width > Self.maxSnapshotWidth {
            configuration.snapshotWidth = NSNumber(value: Double(Self.maxSnapshotWidth))
        }
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

public import AppKit
import CoreImage
import IOSurface
import QuartzCore

// Hover previews. The latest presented frame (``TerminalSurfaceView/presentedFrame``)
// is always available without asking Ghostty to draw.
extension TerminalSurfaceView {
    /// The last presented frame, or nil before the first draw (``GhosttyFrameSource``).
    var presentedFrame: IOSurface? { frameSource.presentedFrame }

    /// Downscaled copy of the last presented frame. One GPU blit; does not
    /// wake the renderer, so it is safe for surfaces that are occluded.
    func snapshot(maxPixelSize: CGFloat) -> CGImage? {
        guard let frame = beginFrameRead() else { return nil }
        defer { endFrameRead(frame) }
        return TerminalSnapshotRenderer.render(SendableSurface(surface: frame), maxPixelSize: maxPixelSize)
    }

    /// Like ``snapshot(maxPixelSize:)`` but renders off the main thread: the
    /// CoreImage render waits for the GPU (`waitUntilCompleted`), which
    /// stalled the main thread 60+ ms under load when a tab was hidden.
    func snapshotInBackground(maxPixelSize: CGFloat) async -> CGImage? {
        guard let frame = beginFrameRead() else { return nil }
        defer { endFrameRead(frame) }
        let surface = SendableSurface(surface: frame)
        return await Task.detached(priority: Task.currentPriority) {
            TerminalSnapshotRenderer.render(surface, maxPixelSize: maxPixelSize)
        }.value
    }
}

/// An IOSurface handed to the snapshot renderer. IOSurfaces are safe to read
/// from any thread; the preview may show a frame Ghostty is replacing.
// crash-allow: one immutable IOSurface reference; IOSurface is a kernel-backed buffer read here only through CoreImage
struct SendableSurface: @unchecked Sendable {
    let surface: IOSurface
}

enum TerminalSnapshotRenderer {
    // crash-allow: an immutable constant; Apple documents CIContext objects as immutable and safe to share among threads
    static nonisolated(unsafe) let context = CIContext(options: [.cacheIntermediates: false, .name: "cmux-next.terminal.snapshot"])

    /// ``render(_:maxPixelSize:)`` off the caller's actor, at the caller's priority: the render waits for the GPU.
    @concurrent nonisolated static func renderOffMain(_ frame: SendableSurface, maxPixelSize: CGFloat) async -> CGImage? {
        render(frame, maxPixelSize: maxPixelSize)
    }

    /// CIContext is thread-safe.
    nonisolated static func render(_ frame: SendableSurface, maxPixelSize: CGFloat) -> CGImage? {
        let image = CIImage(ioSurface: frame.surface)
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixelSize / longest)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        // concurrency-allow: nonisolated; the App calls it through snapshotInBackground (a detached task).
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}

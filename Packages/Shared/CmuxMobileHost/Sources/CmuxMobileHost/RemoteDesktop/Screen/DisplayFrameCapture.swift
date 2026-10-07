#if os(macOS)
public import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures a region of one display with ScreenCaptureKit (IOSurface NV12
/// frames, only when content changed, cursor excluded so the phone draws
/// its own). `setSourceRect` follows the phone's view; `configure` sets the
/// encode size. Needs the app's Screen Recording permission.
public actor DisplayFrameCapture: BrowserFrameCapture {
    private let displayID: CGDirectDisplayID
    private var sourceRect: CGRect
    private var stream: SCStream?
    private let output: ScreenCaptureFrameOutput
    private let delegate: CaptureStopDelegate
    private var width = 0
    private var height = 0
    private var fps = 60

    /// - Parameter sourceRect: the region in display points.
    public init(displayID: CGDirectDisplayID, sourceRect: CGRect) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        let output = ScreenCaptureFrameOutput()
        self.output = output
        // A stream ScreenCaptureKit stops (permission revoked, display gone)
        // ends the frames, so the session ends instead of waiting forever.
        delegate = CaptureStopDelegate { output.finish() }
    }

    public func frames() -> AsyncStream<BrowserCapturedFrame> {
        output.frames
    }

    public func configure(pixelWidth: Int, pixelHeight: Int, maxFPS: Int) async throws {
        width = pixelWidth
        height = pixelHeight
        fps = max(1, maxFPS)
        if let stream {
            try await stream.updateConfiguration(configuration())
        } else {
            try await start()
        }
    }

    public func setSourceRect(_ rect: CGRect) async throws {
        sourceRect = rect
        try await stream?.updateConfiguration(configuration())
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        output.finish()
    }

    private func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RemoteDesktopSourceError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: delegate)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, width)
        configuration.height = max(2, height)
        configuration.sourceRect = sourceRect
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.queueDepth = 3
        return configuration
    }
}
#endif

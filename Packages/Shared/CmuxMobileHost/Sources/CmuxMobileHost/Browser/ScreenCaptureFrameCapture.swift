#if os(macOS)
public import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the page rectangle of one Mac window with ScreenCaptureKit
/// (IOSurface frames, only when content changed). The app passes the tab's
/// window and the page's rect in window points; `updateRect` follows pane
/// resizes. Needs the app's Screen Recording permission.
public actor ScreenCaptureFrameCapture: BrowserFrameCapture {
    private let windowID: CGWindowID
    private var contentRect: CGRect
    private var stream: SCStream?
    private let output = ScreenCaptureFrameOutput()
    private var width = 0
    private var height = 0
    private var fps = 60

    public init(windowID: CGWindowID, contentRect: CGRect) {
        self.windowID = windowID
        self.contentRect = contentRect
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

    /// The page moved or resized inside its window.
    public func updateRect(_ rect: CGRect) async throws {
        contentRect = rect
        try await stream?.updateConfiguration(configuration())
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        output.finish()
    }

    private func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw BrowserPageError.failed("window \(windowID) is not capturable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, width)
        configuration.height = max(2, height)
        configuration.sourceRect = contentRect
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.queueDepth = 3
        return configuration
    }
}
#endif

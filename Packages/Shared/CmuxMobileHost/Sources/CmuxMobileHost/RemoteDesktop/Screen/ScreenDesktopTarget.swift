#if os(macOS)
import CmuxBrowserStream
import CmuxRemoteDesktop
import CoreGraphics
import Foundation

/// A display or window of this Mac: ScreenCaptureKit video through the
/// shared VideoToolbox encoder, CGEvent input, the app's pasteboard.
public actor ScreenDesktopTarget: RemoteDesktopTarget {
    /// The capture behind the video, which owns the crop.
    enum Capture: Sendable {
        case display(DisplayFrameCapture)
        case window(ScreenCaptureFrameCapture)
    }

    public nonisolated let video: any BrowserVideoSource
    public nonisolated var cursor: RemoteDesktopChannelOpened.Cursor { .local }
    private let source: CapturedVideoSource
    private let capture: Capture
    private let targetInfo: DesktopTargetInfo
    private let input: CGEventDesktopInput
    private let pasteboard: any RemoteDesktopPasteboard
    private let eventsStream: AsyncStream<RemoteDesktopTargetEvent>
    private let eventsContinuation: AsyncStream<RemoteDesktopTargetEvent>.Continuation

    init(info: DesktopTargetInfo, capture: Capture, origin: CGPoint, bounds: CGRect, pasteboard: any RemoteDesktopPasteboard) {
        let frames: any BrowserFrameCapture = switch capture {
        case .display(let display): display
        case .window(let window): window
        }
        let source = CapturedVideoSource(capture: frames, encoder: VideoToolboxH264Encoder())
        self.source = source
        video = source
        self.capture = capture
        targetInfo = info
        input = CGEventDesktopInput(origin: origin, scale: info.scale, bounds: bounds)
        self.pasteboard = pasteboard
        (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: RemoteDesktopTargetEvent.self)
    }

    public func info() -> DesktopTargetInfo { targetInfo }

    public func setRegion(_ rect: DesktopRect) async throws {
        let scale = max(targetInfo.scale, 0.1)
        let points = CGRect(x: Double(rect.x) / scale, y: Double(rect.y) / scale, width: Double(rect.width) / scale,
                            height: Double(rect.height) / scale)
        switch capture {
        case .display(let display): try await display.setSourceRect(points)
        case .window(let window): try await window.updateRect(points)
        }
    }

    public func apply(_ event: RdInputEvent) {
        input.apply(event)
    }

    public func pushClipboard(_ text: String) async {
        await pasteboard.writeText(text)
    }

    public func readClipboard() async -> String? {
        await pasteboard.readText()
    }

    public func authenticate(password: String) {}

    public func events() -> AsyncStream<RemoteDesktopTargetEvent> {
        eventsStream
    }

    public func close() async {
        input.releaseAll()
        await source.stop()
        eventsContinuation.finish()
    }
}
#endif

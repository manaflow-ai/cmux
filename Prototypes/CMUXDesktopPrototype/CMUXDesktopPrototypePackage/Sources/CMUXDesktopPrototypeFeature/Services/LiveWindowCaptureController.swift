import AppKit
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

@MainActor
final class LiveWindowCaptureController {
    private var stream: SCStream?
    private var output: WindowStreamOutput?
    private let outputQueue = DispatchQueue(label: "ai.manaflow.cmux.desktopprototype.window-capture")

    func start(window: HostWindow, onFrame: @escaping @MainActor (CGImage) -> Void) async throws {
        await stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw mapCaptureError(error)
        }

        guard let captureWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw LiveWindowCaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
        let outputSize = outputPixelSize(for: filter, fallbackFrame: captureWindow.frame)

        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.scalesToFit = false
        configuration.captureResolution = .best

        let output = WindowStreamOutput(onFrame: onFrame)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)

        self.output = output
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.output = nil
            self.stream = nil
            throw mapCaptureError(error)
        }
    }

    func stop() async {
        guard let stream else {
            output = nil
            return
        }

        try? await stream.stopCapture()
        self.stream = nil
        output = nil
    }

    private func mapCaptureError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code)
        else {
            return error
        }

        switch code {
        case .userDeclined:
            return LiveWindowCaptureError.screenCaptureDenied(restartRequired: CGPreflightScreenCaptureAccess())
        case .missingEntitlements:
            return LiveWindowCaptureError.missingEntitlements
        default:
            return error
        }
    }

    private func outputPixelSize(for filter: SCContentFilter, fallbackFrame: CGRect) -> (width: Int, height: Int) {
        let contentRect = filter.contentRect.isEmpty ? fallbackFrame : filter.contentRect
        let fallbackScale = displayScale(for: contentRect)
        let scale = max(CGFloat(filter.pointPixelScale), fallbackScale, 1)

        return (
            width: max(Int((contentRect.width * scale).rounded(.up)), 1),
            height: max(Int((contentRect.height * scale).rounded(.up)), 1)
        )
    }

    private func displayScale(for frame: CGRect) -> CGFloat {
        NSScreen.screens
            .max { lhs, rhs in
                displayBounds(for: lhs).intersection(frame).area < displayBounds(for: rhs).intersection(frame).area
            }?
            .backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func displayBounds(for screen: NSScreen) -> CGRect {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.frame
        }
        return CGDisplayBounds(CGDirectDisplayID(displayID.uint32Value))
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}

enum LiveWindowCaptureError: LocalizedError {
    case windowUnavailable
    case screenCaptureDenied(restartRequired: Bool)
    case missingEntitlements

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return String(localized: "capture.error.windowUnavailable", defaultValue: "Window is unavailable for live capture", bundle: .module)
        case .screenCaptureDenied(let restartRequired):
            if restartRequired {
                return String(
                    localized: "capture.error.screenCaptureRestartRequired",
                    defaultValue: "Screen Recording is enabled, but macOS has not applied it to this running copy yet. Quit and reopen the app.",
                    bundle: .module
                )
            }
            return String(
                localized: "capture.error.screenCaptureMissing",
                defaultValue: "Screen Recording permission is required for live capture",
                bundle: .module
            )
        case .missingEntitlements:
            return String(
                localized: "capture.error.missingEntitlements",
                defaultValue: "ScreenCaptureKit reported missing capture entitlements",
                bundle: .module
            )
        }
    }
}

private final class WindowStreamOutput: NSObject, SCStreamOutput {
    private let onFrame: @MainActor (CGImage) -> Void
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(onFrame: @escaping @MainActor (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let cgImage = ciContext.createCGImage(image, from: extent) else {
            return
        }

        Task { @MainActor [onFrame] in
            onFrame(cgImage)
        }
    }
}

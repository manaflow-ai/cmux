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
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw mapCaptureError(error)
        }

        guard let captureWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw LiveWindowCaptureError.windowUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(window.frame.width), 1)
        configuration.height = max(Int(window.frame.height), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true

        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
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

import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one application window and publishes decoded frames to the pane.
@MainActor
final class MacAppCaptureSession {
    enum State: Equatable {
        case idle
        case starting
        case streaming
        case permissionRequired
        case failed
    }

    private let catalog: MacAppWindowCatalog
    private let frameQueue = DispatchQueue(label: "com.cmux.mac-app-pane.capture")
    private let imageHandler: @MainActor (CGImage) -> Void
    private let stateHandler: @MainActor (State) -> Void
    private var stream: SCStream?
    private var output: MacAppCaptureOutput?

    init(
        catalog: MacAppWindowCatalog,
        imageHandler: @escaping @MainActor (CGImage) -> Void,
        stateHandler: @escaping @MainActor (State) -> Void
    ) {
        self.catalog = catalog
        self.imageHandler = imageHandler
        self.stateHandler = stateHandler
    }

    func start(descriptor: MacAppWindowDescriptor) async {
        await stop()
        stateHandler(.starting)

        do {
            guard let window = try await catalog.findWindow(for: descriptor) else {
                stateHandler(.failed)
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width * 2))
            configuration.height = max(1, Int(window.frame.height * 2))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let output = MacAppCaptureOutput { [weak self] image in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.imageHandler(image)
                }
            }
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: frameQueue
            )
            try await stream.startCapture()
            self.stream = stream
            self.output = output
            stateHandler(.streaming)
        } catch let error as SCStreamError where error.code == .userDeclined {
            stateHandler(.permissionRequired)
        } catch {
            stateHandler(.failed)
        }
    }

    func stop() async {
        guard let stream else {
            output = nil
            return
        }
        self.stream = nil
        output = nil
        try? await stream.stopCapture()
        stateHandler(.idle)
    }
}

private final class MacAppCaptureOutput: NSObject, SCStreamOutput {
    private let imageHandler: @Sendable (CGImage) -> Void
    private nonisolated let context = CIContext()

    init(imageHandler: @escaping @Sendable (CGImage) -> Void) {
        self.imageHandler = imageHandler
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        imageHandler(image)
    }
}

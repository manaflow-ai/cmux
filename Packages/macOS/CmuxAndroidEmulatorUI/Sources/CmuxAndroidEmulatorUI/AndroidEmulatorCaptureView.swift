import AppKit
import AVFoundation
import CmuxAndroidEmulator
import CoreImage
import ScreenCaptureKit
import SwiftUI

struct AndroidEmulatorCaptureView: NSViewRepresentable {
    let controller: AndroidEmulatorPaneController
    let isVisible: Bool

    func makeNSView(context: Context) -> AndroidEmulatorCaptureNSView {
        let view = AndroidEmulatorCaptureNSView()
        controller.attachCaptureView(view)
        view.onGesture = controller.perform
        return view
    }

    func updateNSView(_ view: AndroidEmulatorCaptureNSView, context: Context) {
        controller.attachCaptureView(view)
        view.onGesture = controller.perform
        view.setVisible(
            isVisible,
            avdName: controller.avdName,
            serial: controller.serial,
            onStarted: controller.clearCaptureError,
            onError: controller.reportCaptureError
        )
    }

    static func dismantleNSView(_ view: AndroidEmulatorCaptureNSView, coordinator: ()) {
        view.stopCapture()
    }
}

@MainActor
final class AndroidEmulatorCaptureNSView: NSView {
    var onGesture: ((AndroidEmulatorControlAction) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var capture: AndroidEmulatorWindowCapture?
    private var captureTask: Task<Void, Never>?
    private var configuration: CaptureConfiguration?
    private var displaySize = AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    private var zoomScale: CGFloat = 1
    private var mouseDownPoint: CGPoint?
    private var mouseDownTimestamp: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layoutDisplayLayer()
    }

    func setDisplaySize(_ size: AndroidEmulatorDisplaySize) {
        guard displaySize != size else { return }
        displaySize = size
        needsLayout = true
    }

    func setZoomScale(_ scale: CGFloat) {
        guard zoomScale != scale else { return }
        zoomScale = scale
        needsLayout = true
    }

    func setVisible(
        _ visible: Bool,
        avdName: String,
        serial: String,
        onStarted: @escaping () -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        let next = CaptureConfiguration(avdName: avdName, serial: serial)
        guard visible else {
            stopCapture()
            return
        }
        guard configuration != next || capture == nil else { return }
        stopCapture()
        configuration = next
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await AndroidEmulatorWindowCapture.start(
                    avdName: avdName,
                    serial: serial,
                    displaySize: displaySize,
                    displayLayer: displayLayer
                )
                guard !Task.isCancelled else {
                    await capture.stop()
                    return
                }
                self.capture = capture
                onStarted()
            } catch {
                onError(error)
            }
        }
    }

    func stopCapture() {
        configuration = nil
        captureTask?.cancel()
        captureTask = nil
        let activeCapture = capture
        capture = nil
        displayLayer.flushAndRemoveImage()
        Task { await activeCapture?.stop() }
    }

    func saveScreenshot() {
        guard let image = capture?.latestImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(configuration?.avdName ?? "android")-screenshot.png"
        panel.title = String(
            localized: "androidEmulator.screenshot.title",
            defaultValue: "Save Android Screenshot",
            bundle: .module
        )
        panel.prompt = String(
            localized: "androidEmulator.screenshot.save",
            defaultValue: "Save",
            bundle: .module
        )
        guard panel.runModal() == .OK, let url = panel.url,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func showVendorWindow() {
        capture?.showVendorWindow()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownTimestamp = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint,
              let startAndroid = androidPoint(for: start),
              let endAndroid = androidPoint(for: convert(event.locationInWindow, from: nil)) else {
            return
        }
        let dx = endAndroid.x - startAndroid.x
        let dy = endAndroid.y - startAndroid.y
        let distance = hypot(Double(dx), Double(dy))
        if distance < 12 {
            onGesture?(.tap(x: startAndroid.x, y: startAndroid.y))
        } else {
            let duration = max(1, Int((event.timestamp - (mouseDownTimestamp ?? event.timestamp)) * 1000))
            onGesture?(.swipe(
                fromX: startAndroid.x,
                fromY: startAndroid.y,
                toX: endAndroid.x,
                toY: endAndroid.y,
                durationMilliseconds: duration
            ))
        }
        mouseDownPoint = nil
        mouseDownTimestamp = nil
    }

    private func layoutDisplayLayer() {
        let aspect = CGFloat(displaySize.width) / CGFloat(displaySize.height)
        let fitWidth = min(bounds.width, bounds.height * aspect)
        let fitHeight = fitWidth / aspect
        let size = CGSize(width: fitWidth * zoomScale, height: fitHeight * zoomScale)
        displayLayer.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    private func androidPoint(for point: CGPoint) -> (x: Int, y: Int)? {
        guard displayLayer.frame.contains(point), displayLayer.frame.width > 0, displayLayer.frame.height > 0 else {
            return nil
        }
        let normalizedX = (point.x - displayLayer.frame.minX) / displayLayer.frame.width
        let normalizedY = 1 - ((point.y - displayLayer.frame.minY) / displayLayer.frame.height)
        return (
            Int((normalizedX * CGFloat(displaySize.width)).rounded()),
            Int((normalizedY * CGFloat(displaySize.height)).rounded())
        )
    }

    private struct CaptureConfiguration: Equatable {
        let avdName: String
        let serial: String
    }
}

private final class AndroidEmulatorWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private nonisolated(unsafe) weak var displayLayer: AVSampleBufferDisplayLayer?
    private nonisolated(unsafe) var latestSampleBuffer: CMSampleBuffer?
    private let stream: SCStream
    private let processIdentifier: pid_t

    private init(stream: SCStream, displayLayer: AVSampleBufferDisplayLayer, processIdentifier: pid_t) {
        self.stream = stream
        self.displayLayer = displayLayer
        self.processIdentifier = processIdentifier
    }

    @MainActor
    static func start(
        avdName: String,
        serial: String,
        displaySize: AndroidEmulatorDisplaySize,
        displayLayer: AVSampleBufferDisplayLayer
    ) async throws -> AndroidEmulatorWindowCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let port = serial.split(separator: "-").last.map(String.init) ?? serial
        guard let window = content.windows.first(where: {
            let title = $0.title ?? ""
            return title.contains(avdName) && title.contains(port)
        }), let application = window.owningApplication else {
            throw AndroidEmulatorCaptureError.windowNotFound(avdName)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let titlebarHeight: CGFloat = 25
        let toolbarWidth: CGFloat = 48
        let availableWidth = max(1, window.frame.width - toolbarWidth)
        let availableHeight = max(1, window.frame.height - titlebarHeight)
        let aspect = CGFloat(displaySize.width) / CGFloat(displaySize.height)
        let deviceWidth = min(availableWidth, availableHeight * aspect)
        let deviceHeight = deviceWidth / aspect
        configuration.sourceRect = CGRect(x: 0, y: titlebarHeight, width: deviceWidth, height: deviceHeight)
        configuration.width = displaySize.width
        configuration.height = displaySize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let capture = AndroidEmulatorWindowCapture(
            stream: stream,
            displayLayer: displayLayer,
            processIdentifier: application.processID
        )
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()
        return capture
    }

    func stop() async {
        try? await stream.stopCapture()
    }

    @MainActor
    func latestImage() -> CGImage? {
        guard let sampleBuffer = latestSampleBuffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    @MainActor
    func showVendorWindow() {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        latestSampleBuffer = sampleBuffer
        displayLayer?.enqueue(sampleBuffer)
    }
}

private enum AndroidEmulatorCaptureError: LocalizedError {
    case windowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let name):
            let format = String(
                localized: "androidEmulator.capture.windowNotFound",
                defaultValue: "The vendor window for “%@” is not available.",
                bundle: .module
            )
            return String(format: format, name)
        }
    }
}

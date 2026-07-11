import AppKit
import AVFoundation
import CmuxAndroidEmulator
import CoreImage
import ScreenCaptureKit
import SwiftUI

struct AndroidEmulatorCaptureView: NSViewRepresentable {
    let controller: AndroidEmulatorPaneController
    let isVisible: Bool
    let sdkRootURL: URL
    let displaySize: AndroidEmulatorDisplaySize
    let retryGeneration: Int

    func makeNSView(context: Context) -> AndroidEmulatorCaptureNSView {
        let view = AndroidEmulatorCaptureNSView()
        controller.attachCaptureView(view)
        view.onGesture = controller.perform
        return view
    }

    func updateNSView(_ view: AndroidEmulatorCaptureNSView, context: Context) {
        controller.attachCaptureView(view)
        view.onGesture = controller.perform
        view.setDisplaySize(displaySize)
        view.setVisible(
            isVisible,
            avdName: controller.avdName,
            serial: controller.serial,
            sdkRootURL: sdkRootURL,
            retryGeneration: retryGeneration,
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
    private let retryWait: @Sendable (Duration) async throws -> Void

    override init(frame frameRect: NSRect) {
        let clock = ContinuousClock()
        self.retryWait = { duration in try await clock.sleep(for: duration) }
        super.init(frame: frameRect)
        configureDisplayLayer()
    }

    init(frame frameRect: NSRect, retryWait: @escaping @Sendable (Duration) async throws -> Void) {
        self.retryWait = retryWait
        super.init(frame: frameRect)
        configureDisplayLayer()
    }

    private func configureDisplayLayer() {
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
        sdkRootURL: URL,
        retryGeneration: Int,
        onStarted: @escaping () -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        let next = CaptureConfiguration(
            avdName: avdName,
            serial: serial,
            sdkRootURL: sdkRootURL,
            displaySize: displaySize,
            retryGeneration: retryGeneration
        )
        guard visible else {
            stopCapture()
            return
        }
        guard configuration != next else { return }
        stopCapture()
        configuration = next
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await startCaptureWithRetry(
                    avdName: avdName,
                    serial: serial,
                    sdkRootURL: sdkRootURL,
                    displaySize: displaySize,
                    displayLayer: displayLayer
                )
                guard !Task.isCancelled else {
                    await capture.stop()
                    return
                }
                self.capture = capture
                onStarted()
            } catch is CancellationError {
                return
            } catch {
                onError(error)
            }
        }
    }

    private func startCaptureWithRetry(
        avdName: String,
        serial: String,
        sdkRootURL: URL,
        displaySize: AndroidEmulatorDisplaySize,
        displayLayer: AVSampleBufferDisplayLayer
    ) async throws -> AndroidEmulatorWindowCapture {
        var retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
        ]
        while true {
            do {
                return try await AndroidEmulatorWindowCapture.start(
                    avdName: avdName,
                    serial: serial,
                    sdkRootURL: sdkRootURL,
                    displaySize: displaySize,
                    displayLayer: displayLayer
                )
            } catch let error as AndroidEmulatorCaptureError {
                guard case .windowNotFound = error, !retryDelays.isEmpty else { throw error }
                let delay = retryDelays.removeFirst()
                try Task.checkCancellation()
                try await retryWait(delay)
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
        let sdkRootURL: URL
        let displaySize: AndroidEmulatorDisplaySize
        let retryGeneration: Int
    }
}

private final class AndroidEmulatorWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private nonisolated(unsafe) weak var displayLayer: AVSampleBufferDisplayLayer?
    private nonisolated(unsafe) var latestSampleBuffer: CMSampleBuffer?
    private let stream: SCStream
    private let processIdentifier: pid_t
    private var isStreamOutputRegistered = false

    private init(stream: SCStream, displayLayer: AVSampleBufferDisplayLayer, processIdentifier: pid_t) {
        self.stream = stream
        self.displayLayer = displayLayer
        self.processIdentifier = processIdentifier
    }

    @MainActor
    static func start(
        avdName: String,
        serial: String,
        sdkRootURL: URL,
        displaySize: AndroidEmulatorDisplaySize,
        displayLayer: AVSampleBufferDisplayLayer
    ) async throws -> AndroidEmulatorWindowCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let deviceAspect = CGFloat(displaySize.width) / CGFloat(displaySize.height)
        let processIdentity = AndroidEmulatorProcessIdentity()
        var processMatchesSelectedAVD: [pid_t: Bool] = [:]
        let window = content.windows
            .filter { window in
                guard window.frame.width > 0,
                      window.frame.height > 0,
                      let processID = window.owningApplication?.processID,
                  let executableURL = NSRunningApplication(processIdentifier: processID)?.executableURL else {
                    return false
                }
                guard AndroidEmulatorCapturePolicy.isExpectedEmulatorExecutable(
                    executableURL,
                    sdkRootURL: sdkRootURL
                ) else {
                    return false
                }
                if let cachedMatch = processMatchesSelectedAVD[processID] {
                    return cachedMatch
                }
                    let matches = processIdentity.matches(
                        processIdentifier: Int32(processID),
                        avdName: avdName,
                        serial: serial
                    )
                processMatchesSelectedAVD[processID] = matches
                return matches
            }
            .min { lhs, rhs in
                let lhsError = AndroidEmulatorCapturePolicy.aspectError(lhs.frame.size, deviceAspect: deviceAspect)
                let rhsError = AndroidEmulatorCapturePolicy.aspectError(rhs.frame.size, deviceAspect: deviceAspect)
                if abs(lhsError - rhsError) > 0.001 {
                    return lhsError < rhsError
                }
                return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
            }
        guard let window, let application = window.owningApplication else {
            throw AndroidEmulatorCaptureError.windowNotFound(avdName)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = AndroidEmulatorCapturePolicy.sourceRect(
            windowSize: window.frame.size,
            displaySize: displaySize
        )
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
        capture.isStreamOutputRegistered = true
        do {
            try await stream.startCapture()
        } catch {
            await capture.stop()
            throw error
        }
        return capture
    }

    @MainActor
    func stop() async {
        try? await stream.stopCapture()
        removeStreamOutputIfNeeded()
        latestSampleBuffer = nil
        displayLayer = nil
    }

    @MainActor
    private func removeStreamOutputIfNeeded() {
        guard isStreamOutputRegistered else { return }
        isStreamOutputRegistered = false
        try? stream.removeStreamOutput(self, type: .screen)
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

enum AndroidEmulatorCapturePolicy {
    static func aspectError(_ windowSize: CGSize, deviceAspect: CGFloat) -> CGFloat {
        abs((windowSize.width / windowSize.height) - deviceAspect)
    }

    static func isExpectedEmulatorExecutable(_ executableURL: URL, sdkRootURL: URL) -> Bool {
        let emulatorDirectory = sdkRootURL
            .appendingPathComponent("emulator", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let directoryComponents = emulatorDirectory.pathComponents
        let executableComponents = executable.pathComponents
        return executableComponents.count > directoryComponents.count
            && executableComponents.starts(with: directoryComponents)
    }

    static func sourceRect(
        windowSize: CGSize,
        displaySize: AndroidEmulatorDisplaySize
    ) -> CGRect {
        let width = max(1, windowSize.width)
        let height = max(1, windowSize.height)
        let aspect = CGFloat(displaySize.width) / CGFloat(displaySize.height)
        let deviceWidth = min(width, height * aspect)
        let deviceHeight = deviceWidth / aspect
        return CGRect(
            x: 0,
            y: max(0, height - deviceHeight),
            width: deviceWidth,
            height: deviceHeight
        )
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

public import CmuxAndroidEmulator
import AppKit
public import Foundation
public import Observation

/// Main-actor projection for one transport-bound emulator pane.
@MainActor @Observable
public final class AndroidEmulatorPaneController {
    public let avdName: String
    public let serial: String
    public let transportID: String
    public let sdkRootURL: URL
    public private(set) var displaySize = AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    public private(set) var isCaptureReady = false
    public private(set) var captureError: String?
    public private(set) var captureRetryGeneration = 0
    public private(set) var operationError: String?
    public private(set) var zoomScale: Double = 1
    public var controlsCollapsed = false

    private let coordinator: AndroidEmulatorCoordinator
    @ObservationIgnored weak var captureView: AndroidEmulatorCaptureNSView?
    @ObservationIgnored private var failedOperation: FailedOperation?
    @ObservationIgnored private var stopConfirmedHandler: (() -> Void)?
    @ObservationIgnored private var stopInFlight = false

    public init(
        avdName: String,
        serial: String,
        transportID: String,
        sdkRootURL: URL,
        coordinator: AndroidEmulatorCoordinator
    ) {
        self.avdName = avdName
        self.serial = serial
        self.transportID = transportID
        self.sdkRootURL = sdkRootURL
        self.coordinator = coordinator
    }

    public func prepare() async {
        guard !isCaptureReady else { return }
        await refreshDisplaySize()
    }

    private func refreshDisplaySize() async {
        do {
            let size = try await coordinator.displaySize(
                avdName: avdName,
                serial: serial,
                transportID: transportID
            )
            displaySize = size
            captureView?.setDisplaySize(size)
            isCaptureReady = true
            clearCaptureError()
        } catch {
            isCaptureReady = false
            reportCaptureError(error)
        }
    }

    public func perform(_ action: AndroidEmulatorControlAction) {
        Task {
            await performControl(action)
        }
    }

    private func performControl(_ action: AndroidEmulatorControlAction) async {
        operationError = nil
        failedOperation = nil
        if let error = await coordinator.perform(
                action,
                avdName: avdName,
                serial: serial,
                transportID: transportID
        ) {
            operationError = AndroidEmulatorPickerView.errorDetail(error)
            failedOperation = .control(action)
            return
        }
        if action == .rotateLeft || action == .rotateRight {
            await refreshDisplaySize()
        }
    }

    public func stop() {
        Task {
            await performStop()
        }
    }

    private func performStop() async {
        guard !stopInFlight else { return }
        stopInFlight = true
        defer { stopInFlight = false }
        operationError = nil
        failedOperation = nil
        if let error = await coordinator.stop(
                avdName: avdName,
                serial: serial,
                transportID: transportID
        ) {
            operationError = AndroidEmulatorPickerView.errorDetail(error)
            failedOperation = .stop
            return
        }
        stopConfirmedHandler?()
    }

    public func cycleZoom() {
        switch zoomScale {
        case ..<1.25: zoomScale = 1.5
        case ..<1.75: zoomScale = 2
        default: zoomScale = 1
        }
        captureView?.setZoomScale(CGFloat(zoomScale))
    }

    public func saveScreenshot() {
        captureView?.saveScreenshot()
    }

    public func showVendorControls() {
        captureView?.showVendorWindow()
    }

    public func retryCapture() {
        captureError = nil
        captureRetryGeneration += 1
    }

    public func retryOperation() {
        guard let failedOperation else { return }
        switch failedOperation {
        case .control(let action):
            perform(action)
        case .stop:
            stop()
        }
    }

    public func setStopConfirmedHandler(_ handler: @escaping () -> Void) {
        stopConfirmedHandler = handler
    }

    public func closePane() {
        captureView?.stopCapture()
    }

    public func focusCapture() {
        guard let captureView, let window = captureView.window else { return }
        window.makeFirstResponder(captureView)
    }

    func attachCaptureView(_ view: AndroidEmulatorCaptureNSView) {
        captureView = view
        view.setDisplaySize(displaySize)
        view.setZoomScale(CGFloat(zoomScale))
    }

    func reportCaptureError(_ error: any Error) {
        captureError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func clearCaptureError() {
        captureError = nil
    }

    private enum FailedOperation {
        case control(AndroidEmulatorControlAction)
        case stop
    }
}

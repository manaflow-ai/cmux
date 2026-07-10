public import CmuxAndroidEmulator
import AppKit
public import Observation

/// Main-actor projection for one transport-bound emulator pane.
@MainActor @Observable
public final class AndroidEmulatorPaneController {
    public let avdName: String
    public let serial: String
    public let transportID: String
    public private(set) var displaySize = AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    public private(set) var captureError: String?
    public private(set) var zoomScale: Double = 1
    public var controlsCollapsed = false

    private let coordinator: AndroidEmulatorCoordinator
    @ObservationIgnored weak var captureView: AndroidEmulatorCaptureNSView?

    public init(
        avdName: String,
        serial: String,
        transportID: String,
        coordinator: AndroidEmulatorCoordinator
    ) {
        self.avdName = avdName
        self.serial = serial
        self.transportID = transportID
        self.coordinator = coordinator
    }

    public func prepare() async {
        if let size = await coordinator.displaySize(
            avdName: avdName,
            serial: serial,
            transportID: transportID
        ) {
            displaySize = size
            captureView?.setDisplaySize(size)
        }
    }

    public func perform(_ action: AndroidEmulatorControlAction) {
        Task {
            await coordinator.perform(
                action,
                avdName: avdName,
                serial: serial,
                transportID: transportID
            )
        }
    }

    public func stop() {
        Task {
            await coordinator.stop(
                avdName: avdName,
                serial: serial,
                transportID: transportID
            )
        }
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
}

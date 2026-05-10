import AppKit
import CoreGraphics
import Observation

struct PermissionState: Equatable {
    var accessibilityTrusted = false
    var screenCaptureAllowed = false
    var screenCaptureNeedsRestart = false
}

struct StatusBanner: Equatable {
    enum Kind {
        case info
        case success
        case warning
        case error
    }

    var kind: Kind
    var message: String
}

@MainActor
@Observable
final class DesktopPrototypeStore {
    var windows: [HostWindow] = []
    var selectedWindowID: CGWindowID?
    var liveFrame: CGImage?
    var isLiveCaptureRunning = false
    var permissions = PermissionState()
    var status: StatusBanner?

    @ObservationIgnored private let enumerator = HostWindowEnumerator()
    @ObservationIgnored private let snapshotter = WindowSnapshotter()
    @ObservationIgnored private let accessibilityController = AccessibilityWindowController()
    @ObservationIgnored private let captureController = LiveWindowCaptureController()
    @ObservationIgnored private let inputForwarder = WindowInputForwarder()
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var screenCaptureNeedsRestart = false

    var selectedWindow: HostWindow? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    func reloadWindows() {
        updatePermissions()
        windows = enumerator.windows()

        if let selectedWindowID, windows.contains(where: { $0.id == selectedWindowID }) {
            restartLiveCapture()
        } else {
            selectedWindowID = windows.first?.id
            restartLiveCapture()
        }

        status = StatusBanner(
            kind: .success,
            message: String(localized: "status.refreshed", defaultValue: "Window list refreshed", bundle: .module)
        )
    }

    func selectWindow(_ id: CGWindowID) {
        selectedWindowID = id
        restartLiveCapture()
    }

    func restartLiveCapture() {
        updatePermissions()
        guard let selectedWindow else {
            liveFrame = nil
            isLiveCaptureRunning = false
            return
        }

        liveFrame = nil
        isLiveCaptureRunning = false
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.startLiveCapture(for: selectedWindow)
        }
    }

    func requestAccessibilityPermission() {
        accessibilityController.requestPermission()
        if !accessibilityController.isTrusted {
            accessibilityController.openAccessibilitySettings()
        }
        updatePermissions()
        status = StatusBanner(
            kind: .info,
            message: String(localized: "status.accessibilityRequested", defaultValue: "Accessibility request sent. System Settings opened if approval is still needed.", bundle: .module)
        )
    }

    func requestScreenCapturePermission() {
        snapshotter.requestScreenCaptureAccess()
        if !snapshotter.hasScreenCaptureAccess {
            snapshotter.openScreenCaptureSettings()
        }
        updatePermissions()
        restartLiveCapture()
        status = StatusBanner(
            kind: .info,
            message: String(localized: "status.screenRequested", defaultValue: "Screen Recording request sent. System Settings opened if approval is still needed.", bundle: .module)
        )
    }

    func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    let format = String(localized: "status.relaunchFailed", defaultValue: "Relaunch failed: %@", bundle: .module)
                    self?.status = StatusBanner(kind: .error, message: String(format: format, error.localizedDescription))
                }
                return
            }

            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func raiseSelectedWindow() {
        guard let selectedWindow else {
            return
        }
        apply(accessibilityController.raise(selectedWindow), refreshAfterSuccess: true)
    }

    func placeSelectedWindow(_ placement: WindowPlacement) {
        guard let selectedWindow else {
            return
        }
        apply(accessibilityController.place(selectedWindow, placement: placement), refreshAfterSuccess: true)
    }

    func forwardMouseInput(_ input: WindowMouseInput) {
        guard let selectedWindow else {
            return
        }
        applyInputResult(inputForwarder.forwardMouse(input, to: selectedWindow))
    }

    func forwardScrollInput(_ input: WindowScrollInput) {
        guard let selectedWindow else {
            return
        }
        applyInputResult(inputForwarder.forwardScroll(input, to: selectedWindow))
    }

    func forwardKeyInput(_ input: WindowKeyInput) {
        guard let selectedWindow else {
            return
        }
        applyInputResult(inputForwarder.forwardKey(input, to: selectedWindow))
    }

    private func startLiveCapture(for window: HostWindow) async {
        await captureController.stop()

        guard !Task.isCancelled else {
            return
        }

        do {
            try await captureController.start(window: window) { [weak self] frame in
                self?.liveFrame = frame
                self?.isLiveCaptureRunning = true
            }
            screenCaptureNeedsRestart = false
            updatePermissions()
            status = StatusBanner(
                kind: .success,
                message: String(localized: "status.liveStarted", defaultValue: "Live capture started", bundle: .module)
            )
        } catch {
            guard !Task.isCancelled else {
                return
            }

            isLiveCaptureRunning = false
            if case LiveWindowCaptureError.screenCaptureDenied(let restartRequired) = error {
                screenCaptureNeedsRestart = restartRequired
                updatePermissions()
            }
            let format = String(localized: "status.liveFailed", defaultValue: "Live capture failed: %@", bundle: .module)
            status = StatusBanner(kind: .error, message: String(format: format, error.localizedDescription))
        }
    }

    private func apply(_ result: AccessibilityActionResult, refreshAfterSuccess: Bool) {
        updatePermissions()
        switch result {
        case .succeeded:
            if refreshAfterSuccess {
                windows = enumerator.windows()
                restartLiveCapture()
            }
            status = StatusBanner(
                kind: .success,
                message: String(localized: "status.actionSucceeded", defaultValue: "Window updated", bundle: .module)
            )
        case .accessibilityPermissionMissing:
            status = StatusBanner(
                kind: .warning,
                message: String(localized: "status.accessibilityMissing", defaultValue: "Accessibility permission missing", bundle: .module)
            )
        case .windowUnavailable:
            status = StatusBanner(
                kind: .warning,
                message: String(localized: "status.windowNotFound", defaultValue: "Window unavailable", bundle: .module)
            )
        case .failed(let error):
            let format = String(localized: "status.actionFailed", defaultValue: "Window action failed: %@", bundle: .module)
            status = StatusBanner(kind: .error, message: String(format: format, String(describing: error)))
        }
    }

    private func applyInputResult(_ result: WindowInputResult) {
        updatePermissions()
        switch result {
        case .succeeded:
            break
        case .accessibilityPermissionMissing:
            status = StatusBanner(
                kind: .warning,
                message: String(localized: "status.inputAccessibilityMissing", defaultValue: "Accessibility permission is needed before forwarding input", bundle: .module)
            )
        case .eventCreationFailed:
            status = StatusBanner(
                kind: .error,
                message: String(localized: "status.inputFailed", defaultValue: "Input event could not be created", bundle: .module)
            )
        }
    }

    private func updatePermissions() {
        let hasScreenCaptureAccess = snapshotter.hasScreenCaptureAccess
        permissions = PermissionState(
            accessibilityTrusted: accessibilityController.isTrusted,
            screenCaptureAllowed: hasScreenCaptureAccess && !screenCaptureNeedsRestart,
            screenCaptureNeedsRestart: hasScreenCaptureAccess && screenCaptureNeedsRestart
        )
    }
}

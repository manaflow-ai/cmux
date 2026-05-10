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
    var renderMode: DesktopRenderMode = .video
    var permissions = PermissionState()
    var status: StatusBanner?

    @ObservationIgnored private let enumerator = HostWindowEnumerator()
    @ObservationIgnored private let snapshotter = WindowSnapshotter()
    @ObservationIgnored private let accessibilityController = AccessibilityWindowController()
    @ObservationIgnored private let captureController = LiveWindowCaptureController()
    @ObservationIgnored private let inputForwarder = WindowInputForwarder()
    @ObservationIgnored private let frameObserver = HostWindowFrameObserver()
    @ObservationIgnored private let nativeProjectionController = NativeWindowProjectionController()
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var nativeSlotFrame: NativeWindowSlotFrame?
    @ObservationIgnored private var screenCaptureNeedsRestart = false

    var selectedWindow: HostWindow? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    func reloadWindows() {
        updatePermissions()
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.loadWindows()
        }
    }

    private func loadWindows() async {
        let loadedWindows = await enumerator.windows()
        guard !Task.isCancelled else {
            return
        }

        windows = loadedWindows

        if let selectedWindowID, windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowDidChange()
        } else {
            selectedWindowID = windows.first?.id
            selectedWindowDidChange()
        }

        status = StatusBanner(
            kind: .success,
            message: String(localized: "status.refreshed", defaultValue: "Window list refreshed", bundle: .module)
        )
    }

    func selectWindow(_ id: CGWindowID) {
        selectedWindowID = id
        selectedWindowDidChange()
    }

    func setRenderMode(_ mode: DesktopRenderMode) {
        guard renderMode != mode else {
            return
        }

        renderMode = mode
        switch mode {
        case .video:
            nativeProjectionController.stop()
            restartLiveCapture()
        case .native:
            stopLiveCapture()
            if let selectedWindow {
                nativeProjectionController.start(window: selectedWindow)
                placeNativeWindowIfPossible()
            }
        }
    }

    func updateNativeSlotFrame(_ slotFrame: NativeWindowSlotFrame) {
        guard nativeSlotFrame != slotFrame else {
            return
        }

        nativeSlotFrame = slotFrame
        placeNativeWindowIfPossible()
    }

    func restartLiveCapture() {
        updatePermissions()
        guard renderMode == .video else {
            stopLiveCapture()
            return
        }
        guard let selectedWindow else {
            stopLiveCapture()
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

    private func stopLiveCapture() {
        liveFrame = nil
        isLiveCaptureRunning = false
        captureTask?.cancel()
        captureTask = Task { [captureController] in
            await captureController.stop()
        }
    }

    private func selectedWindowDidChange() {
        observeSelectedWindow()
        switch renderMode {
        case .video:
            nativeProjectionController.stop()
            restartLiveCapture()
        case .native:
            stopLiveCapture()
            if let selectedWindow {
                nativeProjectionController.start(window: selectedWindow)
                placeNativeWindowIfPossible()
            } else {
                nativeProjectionController.stop()
            }
        }
    }

    private func observeSelectedWindow() {
        guard let selectedWindow else {
            frameObserver.stop()
            return
        }

        let result = frameObserver.start(window: selectedWindow) { [weak self] frame in
            self?.selectedWindowFrameDidChange(frame)
        }

        if result == .accessibilityPermissionMissing {
            updatePermissions()
        }
    }

    private func selectedWindowFrameDidChange(_ frame: CGRect) {
        guard let selectedWindowID,
              let index = windows.firstIndex(where: { $0.id == selectedWindowID })
        else {
            return
        }

        let previousWindow = windows[index]
        guard !previousWindow.frame.isApproximatelyEqual(to: frame) else {
            return
        }

        let updatedWindow = previousWindow.with(frame: frame, isOnScreen: true)
        windows[index] = updatedWindow
        nativeProjectionController.updateWindow(updatedWindow)

        switch renderMode {
        case .video:
            if !previousWindow.frame.size.isApproximatelyEqual(to: frame.size) {
                restartLiveCapture()
            }
        case .native:
            if previousWindow.frame.size.isApproximatelyEqual(to: frame.size) {
                placeNativeWindowIfPossible()
            }
        }
    }

    private func placeNativeWindowIfPossible() {
        guard renderMode == .native,
              let selectedWindow,
              let nativeSlotFrame
        else {
            return
        }

        let result = nativeProjectionController.place(window: selectedWindow, in: nativeSlotFrame)
        handleNativePlacementResult(result)
    }

    private func handleNativePlacementResult(_ result: AccessibilityActionResult) {
        updatePermissions()
        switch result {
        case .succeeded:
            break
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

    private func apply(_ result: AccessibilityActionResult, refreshAfterSuccess: Bool) {
        updatePermissions()
        switch result {
        case .succeeded:
            if refreshAfterSuccess {
                reloadWindows()
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

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize) -> Bool {
        abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1
            && abs(minY - other.minY) < 1
            && size.isApproximatelyEqual(to: other.size)
    }
}

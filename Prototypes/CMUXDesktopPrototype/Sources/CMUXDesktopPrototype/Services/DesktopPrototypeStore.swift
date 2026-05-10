import AppKit
import CoreGraphics
import Observation

struct PermissionState: Equatable {
    var accessibilityTrusted = false
    var screenCaptureAllowed = false
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
    var selectedSnapshot: NSImage?
    var permissions = PermissionState()
    var status: StatusBanner?

    @ObservationIgnored private let enumerator = HostWindowEnumerator()
    @ObservationIgnored private let snapshotter = WindowSnapshotter()
    @ObservationIgnored private let accessibilityController = AccessibilityWindowController()

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
            refreshSnapshot()
        } else {
            selectedWindowID = windows.first?.id
            refreshSnapshot()
        }

        status = StatusBanner(
            kind: .success,
            message: String(localized: "status.refreshed", defaultValue: "Window list refreshed", bundle: .module)
        )
    }

    func selectWindow(_ id: CGWindowID) {
        selectedWindowID = id
        refreshSnapshot()
    }

    func refreshSnapshot() {
        updatePermissions()
        guard let selectedWindow else {
            selectedSnapshot = nil
            return
        }
        selectedSnapshot = snapshotter.snapshot(for: selectedWindow)
    }

    func requestAccessibilityPermission() {
        accessibilityController.requestPermission()
        updatePermissions()
        status = StatusBanner(
            kind: .info,
            message: String(localized: "status.accessibilityRequested", defaultValue: "Accessibility request sent", bundle: .module)
        )
    }

    func requestScreenCapturePermission() {
        snapshotter.requestScreenCaptureAccess()
        updatePermissions()
        refreshSnapshot()
        status = StatusBanner(
            kind: .info,
            message: String(localized: "status.screenRequested", defaultValue: "Screen Recording request sent", bundle: .module)
        )
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

    private func apply(_ result: AccessibilityActionResult, refreshAfterSuccess: Bool) {
        updatePermissions()
        switch result {
        case .succeeded:
            if refreshAfterSuccess {
                windows = enumerator.windows()
                refreshSnapshot()
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

    private func updatePermissions() {
        permissions = PermissionState(
            accessibilityTrusted: accessibilityController.isTrusted,
            screenCaptureAllowed: snapshotter.hasScreenCaptureAccess
        )
    }
}

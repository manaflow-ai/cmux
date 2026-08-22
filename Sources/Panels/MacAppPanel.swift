import AppKit
import Combine
import Foundation

/// Owns the selected application window and its ScreenCaptureKit lifecycle.
@MainActor
final class MacAppPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .macApp

    @Published private(set) var availableWindows: [MacAppWindowDescriptor] = []
    @Published private(set) var selectedWindow: MacAppWindowDescriptor?
    @Published private(set) var latestImage: NSImage?
    @Published private(set) var captureState: MacAppCaptureSession.State = .idle
    @Published private(set) var isLoadingWindows = false
    @Published private(set) var requiresAccessibilityPermission = false
    @Published private(set) var requiresScreenRecordingPermission = false

    private let catalog = MacAppWindowCatalog()
    private lazy var capture = MacAppCaptureSession(
        catalog: catalog,
        imageHandler: { [weak self] image in
            self?.latestImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        },
        stateHandler: { [weak self] state in
            self?.captureState = state
        }
    )
    private var windowLoadTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private weak var surfaceView: NSView?
    private var isClosed = false

    var displayTitle: String {
        selectedWindow?.applicationName ?? String(
            localized: "macApp.pane.title",
            defaultValue: "Mac App"
        )
    }

    var displayIcon: String? { "macwindow" }

    var isStreaming: Bool {
        captureState == .streaming
    }

    func refreshWindows() {
        windowLoadTask?.cancel()
        isLoadingWindows = true
        windowLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoadingWindows = false }
            do {
                availableWindows = try await catalog.loadWindows()
                requiresAccessibilityPermission = !AXIsProcessTrusted()
                requiresScreenRecordingPermission = false
            } catch {
                availableWindows = []
                requiresAccessibilityPermission = !AXIsProcessTrusted()
                requiresScreenRecordingPermission = true
                captureState = .permissionRequired
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }

    func selectWindow(_ descriptor: MacAppWindowDescriptor) {
        guard !isClosed else { return }
        selectedWindow = descriptor
        latestImage = nil
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await capture.start(descriptor: descriptor)
        }
    }

    func clearSelection() {
        selectedWindow = nil
        latestImage = nil
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            await self?.capture.stop()
        }
    }

    func setSurfaceView(_ view: NSView?) {
        surfaceView = view
    }

    func setVisibleInUI(_ visible: Bool) {
        guard !isClosed else { return }
        if visible {
            guard let selectedWindow, !isStreaming else { return }
            captureTask?.cancel()
            captureTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await capture.start(descriptor: selectedWindow)
            }
        } else {
            captureTask?.cancel()
            captureTask = Task { @MainActor [weak self] in
                await self?.capture.stop()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        windowLoadTask?.cancel()
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            await self?.capture.stop()
        }
    }

    func focus() {
        surfaceView?.window?.makeFirstResponder(surfaceView)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        guard let surfaceView,
              responder === surfaceView,
              surfaceView.window === window else {
            return nil
        }
        return .panel
    }

    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent == .panel,
              let surfaceView,
              surfaceView.window === window,
              window.firstResponder === surfaceView else {
            return false
        }
        return window.makeFirstResponder(nil)
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        guard let window,
              let surfaceView,
              window.firstResponder === surfaceView else {
            return .panel
        }
        return .panel
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent { .panel }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }
}

public import AppKit
internal import CmuxTerminalFrontend
public import SwiftUI

@MainActor
private final class BackendOnlyTerminalViewportHostView: NSView {
    private let runtime: BackendOnlyTerminalRuntime
    private let interactionView: TerminalFrontendInteractionView
    private var presentationLease: (any TerminalExternalPresentationLease)?
    private var lastViewport: TerminalExternalViewport?
    private var mouseMovedEventsLease: BackendOnlyWindowMouseMovedEventsLease?

    init(runtime: BackendOnlyTerminalRuntime) {
        self.runtime = runtime
        interactionView = TerminalFrontendInteractionView(
            runtime: runtime,
            responderFocusOwnership: .externalHost
        )
        super.init(frame: .zero)
        interactionView.responderFocusDidChange = { [weak self] responderFocused in
            self?.publishPresentationState(responderFocused: responderFocused)
        }
        interactionView.frame = bounds
        interactionView.autoresizingMask = [.width, .height]
        addSubview(interactionView)
        runtime.bindSurfaceView(interactionView.surfaceView)
        presentationLease = runtime.attachPresentation(
            TerminalExternalPresentation(
                surfaceID: runtime.selection.surfaceID.rawValue,
                workspaceID: runtime.selection.workspaceID.rawValue
            )
        )
    }

    @available(*, unavailable, message: "Construct with a backend terminal runtime")
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        stopObservingWindow()
        presentationLease?.detach()
    }

    override func layout() {
        super.layout()
        interactionView.frame = bounds
        publishViewportIfChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        if let window {
            mouseMovedEventsLease = BackendOnlyWindowMouseMovedEventsLease(window: window)
            observe(window)
            publishViewportIfChanged()
            window.makeFirstResponder(interactionView)
        }
        publishPresentationState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastViewport = nil
        publishViewportIfChanged()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        lastViewport = nil
        publishViewportIfChanged()
    }

    private func publishViewportIfChanged() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        let backingBounds = convertToBacking(bounds)
        let widthPixels = max(1, Int(backingBounds.width.rounded(.up)))
        let heightPixels = max(1, Int(backingBounds.height.rounded(.up)))
        let metrics = runtime.snapshot.cellMetrics
        let proposedColumns: Int?
        let proposedRows: Int?
        if let metrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 {
            let horizontalPadding = if let left = metrics.paddingLeftPixels,
                                       let right = metrics.paddingRightPixels {
                left + right
            } else {
                max(
                    0,
                    metrics.surfaceWidthPixels - metrics.columns * metrics.cellWidthPixels
                )
            }
            let verticalPadding = if let top = metrics.paddingTopPixels,
                                     let bottom = metrics.paddingBottomPixels {
                top + bottom
            } else {
                max(
                    0,
                    metrics.surfaceHeightPixels - metrics.rows * metrics.cellHeightPixels
                )
            }
            proposedColumns = max(
                1,
                (widthPixels - horizontalPadding) / metrics.cellWidthPixels
            )
            proposedRows = max(
                1,
                (heightPixels - verticalPadding) / metrics.cellHeightPixels
            )
        } else {
            proposedColumns = nil
            proposedRows = nil
        }
        let viewport = TerminalExternalViewport(
            widthPoints: bounds.width,
            heightPoints: bounds.height,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            xScale: scale,
            yScale: scale,
            proposedColumns: proposedColumns,
            proposedRows: proposedRows
        )
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        runtime.setHostViewport(viewport)
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didOrderOnScreenNotification,
            NSWindow.didOrderOffScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(windowPresentationStateChanged),
                name: name,
                object: window
            )
        }
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(windowPresentationStateChanged),
                name: name,
                object: nil
            )
        }
    }

    private func stopObservingWindow() {
        NotificationCenter.default.removeObserver(self)
        mouseMovedEventsLease?.invalidate()
        mouseMovedEventsLease = nil
    }

    @objc private func windowPresentationStateChanged() {
        if window?.backingScaleFactor != lastViewport?.xScale {
            lastViewport = nil
            publishViewportIfChanged()
        }
        publishPresentationState()
    }

    private func publishPresentationState(responderFocused: Bool? = nil) {
        guard let window else {
            runtime.setHostFocus(false)
            runtime.setHostVisibility(false)
            return
        }
        let visible = !isHiddenOrHasHiddenAncestor
            && window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        let focused = visible
            && NSApp.isActive
            && window.isKeyWindow
            && (responderFocused ?? (window.firstResponder === interactionView))
        runtime.setHostVisibility(visible)
        runtime.setHostFocus(focused)
    }
}

/// SwiftUI bridge for the selected daemon-owned terminal workspace.
public struct BackendOnlyTerminalView: NSViewRepresentable {
    public let runtime: BackendOnlyTerminalRuntime

    public init(runtime: BackendOnlyTerminalRuntime) {
        self.runtime = runtime
    }

    public func makeNSView(context: Context) -> NSView {
        BackendOnlyTerminalViewportHostView(runtime: runtime)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        nsView.needsLayout = true
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.removeFromSuperview()
    }
}

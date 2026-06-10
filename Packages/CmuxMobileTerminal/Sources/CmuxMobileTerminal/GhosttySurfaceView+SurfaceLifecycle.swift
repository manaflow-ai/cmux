#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Surface Lifecycle (create, init, dispose, reuse)
extension GhosttySurfaceView {
    /// Stops user-visible and accessibility output from a surface SwiftUI has removed.
    public func prepareForDismantle() {
        isDismantled = true
        prepareForReuseAfterDetach()
    }

    /// Quiesces the surface on window detach: resigns input, stops the display
    /// link, drops focus, and removes the debug accessibility carrier from the
    /// tree. Does not set ``isDismantled`` so a transient detach can re-attach
    /// and resume; only ``prepareForDismantle()`` marks the surface dead.
    func prepareForReuseAfterDetach() {
        resignInput()
        stopDisplayLink()
        setFocus(false)
        #if DEBUG
        debugAccessibilityProxy.accessibilityLabel = nil
        debugAccessibilityProxy.isAccessibilityElement = false
        #endif
    }

    func disposeSurface() {
        stopDisplayLink()
        guard let surface else { return }
        GhosttySurfaceView.unregister(surface: surface)
        self.surface = nil
        bridge.detach()
        // Free on the SAME serial `outputQueue` that runs `process_output`,
        // `render_now`, and `binding_action` (all of which capture this C
        // surface pointer), not a separate queue. FIFO ordering guarantees the
        // free runs after every already-enqueued block that captured the
        // pointer, so a dismantled/removed surface's queued libghostty work can
        // never use-after-free against the free, and no two of them ever touch
        // the surface concurrently. `processOutput`'s main-actor guard stops new
        // work from being enqueued once `surface` is nil, so only the bounded
        // backlog drains before the free. (Retain the bridge across the hop; it
        // owns the userdata libghostty still references until the free.)
        let retainedBridge = Unmanaged.passRetained(bridge)
        Self.outputQueue.async {
            ghostty_surface_free(surface)
            retainedBridge.release()
        }
    }

    var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app)
        if let surface {
            GhosttySurfaceView.register(surface: surface, for: self)
            if let config = runtime?.config {
                applyBackgroundColorFromConfig(config)
            }
            // Hide the snapshot fallback immediately. The Metal renderer
            // handles all rendering once the surface exists.
            snapshotFallbackView.isHidden = true
            surfaceHasReceivedOutput = true
        }
        setNeedsGeometrySync()
        startDisplayLink()
    }

    private func makeSurface(app: ghostty_app_t) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = fontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buf, len in
            guard let userdata, let buf, len > 0 else { return }
            let data = Data(bytes: buf, count: Int(len))
            let bridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.surfaceView?.handleOutboundBytes(data)
            }
        }
        surfaceConfig.io_write_userdata = bridgePointer
        return ghostty_surface_new(app, &surfaceConfig)
    }

}

#endif

import AppKit
import Foundation

#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Headless bootstrap windows

extension TerminalSurface {
    @MainActor
    func scheduleHeadlessRuntimeStartIfNeeded(
        reason: String,
        source: RuntimeSurfaceCreationSource = .normal
    ) {
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason, source: source)
    }

    @MainActor
    private func startRuntimeUsingHeadlessWindowIfNeeded(
        reason: String,
        source: RuntimeSurfaceCreationSource
    ) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        ensureHeadlessStartupWindowIfNeeded(reason: reason)
        // Production pane hosts synchronously call attachToView; carry the requested creation source through that callback.
        let previousAttachCreationSource = paneHostAttachCreationSource
        paneHostAttachCreationSource = source
        paneHost.attachSurface(self)
        paneHostAttachCreationSource = previousAttachCreationSource
        if source == .inputDemand, surface == nil, attachedView !== surfaceView {
            attachToViewForInputDemand(surfaceView)
        }
    }

    @MainActor
    private func ensureHeadlessStartupWindowIfNeeded(reason: String) {
        if let existingWindow = headlessStartupWindow {
            guard paneHost.window !== existingWindow else { return }
            if paneHost.window != nil {
                // The pane host reached a real window while a bootstrap
                // window was still recorded; the bootstrap is stale.
                headlessStartupWindow = nil
                existingWindow.contentView = nil
                existingWindow.close()
                return
            }
            // Window-portal churn can reparent the pane host out of the
            // bootstrap window and park it with no window at all
            // (detachHostedView ends in removeFromSuperview). Reclaim custody
            // instead of early-returning: otherwise every later cold start
            // defers on the missing window and the surface never spawns a
            // PTY (#9769).
            adoptPaneHostIntoHeadlessStartupWindow(existingWindow, reason: reason)
            return
        }
        guard paneHost.window == nil else { return }
        let width = max(surfaceView.bounds.width, CGFloat(800))
        let height = max(surfaceView.bounds.height, CGFloat(600))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true
        window.contentView = NSView(frame: frame)
        headlessStartupWindow = window
        adoptPaneHostIntoHeadlessStartupWindow(window, reason: reason)

        #if DEBUG
        logDebugEvent(
            "surface.headless_window.create surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
        #endif
    }

    @MainActor
    private func adoptPaneHostIntoHeadlessStartupWindow(_ window: NSWindow, reason: String) {
        guard let contentView = window.contentView else { return }
        paneHost.frame = contentView.bounds
        paneHost.autoresizingMask = [.width, .height]
        contentView.addSubview(paneHost)
        paneHost.setVisibleInUI(false)
        paneHost.setActive(false)

        #if DEBUG
        logDebugEvent(
            "surface.headless_window.adopt surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
        #endif
    }

    @MainActor
    func releaseHeadlessStartupWindowIfNeeded(for view: any TerminalSurfaceNativeViewing) {
        guard let window = headlessStartupWindow else { return }
        guard let currentWindow = view.window, currentWindow !== window else { return }
        headlessStartupWindow = nil
        window.contentView = nil
        window.close()
        #if DEBUG
        logDebugEvent(
            "surface.headless_window.release surface=\(id.uuidString.prefix(8)) " +
            "realWindow=\(ObjectIdentifier(currentWindow))"
        )
        #endif
    }

    @MainActor
    func closeHeadlessStartupWindowIfNeeded() {
        // Isolation note: the legacy helper accepted off-main callers with a
        // Thread.isMainThread check + main-queue hop. Every caller
        // (teardownSurface, agent-hibernation suspend) is main-actor isolated,
        // so the hop was dead and the method is now @MainActor; deinit has its
        // own transport-based hop.
        let startupWindow = headlessStartupWindow
        headlessStartupWindow = nil
        guard let startupWindow else { return }
        startupWindow.contentView = nil
        startupWindow.close()
    }
}

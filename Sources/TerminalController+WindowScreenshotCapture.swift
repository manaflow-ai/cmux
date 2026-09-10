import AppKit
import Foundation
import ScreenCaptureKit
import WebKit

#if DEBUG
extension TerminalController {
    nonisolated func captureScreenshot(_ args: String) -> String {
        guard !Thread.isMainThread else {
            return "ERROR: screenshot must run off the main thread"
        }

        // Parse optional label from args
        let label = WindowScreenshotLabel(args).value

        // Generate unique ID for this screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let screenshotId = "\(timestamp)_\(shortId)"

        // Determine output path
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let filename = label.isEmpty ? "\(screenshotId).png" : "\(label)_\(screenshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        let captureTarget: CGWindowID? = v2MainSync {
            let candidateWindows = NSApp.windows.filter { window in
                window.isVisible &&
                    !window.isMiniaturized &&
                    window.contentView != nil &&
                    !window.frame.isEmpty
            }
            let window = WindowScreenshotWindowSelector.select(
                eligibleWindows: candidateWindows,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                terminalWindow: self.tabManager?.window
            )
            guard let window else { return nil }
            return WindowScreenshotTarget(
                windowNumber: window.windowNumber
            )?.windowID
        }
        guard let captureTarget else {
            return "ERROR: No window available"
        }

        // Prefer the system compositor when policy permits it, and avoid the
        // heavier main-actor fallback on the normal path. Independent backend
        // admission keeps a stalled compositor from accumulating more work or
        // blocking the permission-free AppKit fallback.
        let screenCaptureKitAttempt = captureScreenCaptureKitWindowPNGData(
            captureTarget
        )
        let pngData: Data
        if let captured = screenCaptureKitAttempt.capturedValue {
            pngData = captured
        } else {
            let appKitAttempt = captureAppKitWindowPNGData(captureTarget)
            guard let captured = appKitAttempt.capturedValue else {
                if appKitAttempt.isBusy || screenCaptureKitAttempt.isBusy {
                    return "ERROR: screenshot capture already in progress"
                }
                if appKitAttempt.didTimeOut || screenCaptureKitAttempt.didTimeOut {
                    return "ERROR: screenshot capture timed out"
                }
                return "ERROR: Failed to create PNG data"
            }
            pngData = captured.pngData
        }

        do {
            try pngData.write(to: outputPath)
        } catch {
            return "ERROR: Failed to write file: \(error.localizedDescription)"
        }

        // Return OK with screenshot ID and path for easy reference
        return "OK \(screenshotId) \(outputPath.path)"
    }

    private nonisolated func captureScreenCaptureKitWindowPNGData(
        _ windowID: CGWindowID
    ) -> WindowScreenshotBackendAttempt<Data> {
        guard Self.screenCaptureKitMayRunWithoutPrompt else {
            return .unavailable
        }
        guard let captureLease = windowScreenshotCaptureCoordinator
            .claimScreenCaptureKit() else {
            return .busy
        }
        let captureTask = Task {
            defer { captureLease.retire() }
            return await Self.captureScreenCaptureKitWindowPNGDataAsync(windowID)
        }
        let captured: Data?? = socketAwaitCallback(timeout: 5) { completion in
            Task {
                completion(await captureTask.value)
            }
        }
        guard let captured else {
            captureTask.cancel()
            return .timedOut
        }
        guard let captured else { return .unavailable }
        return .captured(captured)
    }

    private nonisolated static var screenCaptureKitMayRunWithoutPrompt: Bool {
        if #available(macOS 14.4, *) {
            return WindowScreenshotScreenCapturePolicy(
                currentProcessAPIAvailable: true,
                screenCaptureAccessGranted: false
            ).allowsScreenCaptureKit
        }
        return WindowScreenshotScreenCapturePolicy(
            currentProcessAPIAvailable: false,
            screenCaptureAccessGranted: CGPreflightScreenCaptureAccess()
        ).allowsScreenCaptureKit
    }

    private nonisolated static func captureScreenCaptureKitWindowPNGDataAsync(
        _ windowID: CGWindowID
    ) async -> Data? {
        do {
            let shareableContent: SCShareableContent
            if #available(macOS 14.4, *) {
                // This current-process-only query captures cmux's own windows
                // without requesting Screen Recording permission.
                shareableContent = try await SCShareableContent.currentProcess
            } else {
                // macOS 14.0–14.3 lacks the permission-free current-process
                // query. Use the older ScreenCaptureKit inventory solely to
                // locate our exact window ID; denial falls back to AppKit.
                shareableContent = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
            }
            guard let window = shareableContent.windows.first(where: {
                $0.windowID == windowID
            }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let contentInfo = SCShareableContent.info(for: filter)
            let scale = CGFloat(contentInfo.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(ceil(contentInfo.contentRect.width * scale)))
            configuration.height = max(1, Int(ceil(contentInfo.contentRect.height * scale)))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            )
        } catch {
            return nil
        }
    }

    private nonisolated func captureAppKitWindowPNGData(
        _ windowID: CGWindowID
    ) -> WindowScreenshotBackendAttempt<WindowAppKitCapture> {
        guard let captureLease = windowScreenshotCaptureCoordinator
            .claimAppKit() else {
            return .busy
        }
        let captureTask = Task { @MainActor in
            defer { captureLease.retire() }
            return await self.captureAppKitWindowPNGDataOnMain(windowID)
        }
        let captured: WindowAppKitCapture?? = socketAwaitCallback(
            timeout: 5
        ) { completion in
            Task {
                completion(await captureTask.value)
            }
        }
        guard let captured else {
            captureTask.cancel()
            return .timedOut
        }
        guard let captured else { return .unavailable }
        return .captured(captured)
    }

    @MainActor
    private func captureAppKitWindowPNGDataOnMain(
        _ windowID: CGWindowID
    ) async -> WindowAppKitCapture? {
        guard let window = NSApp.windows.first(where: {
            WindowScreenshotTarget(windowNumber: $0.windowNumber)?.windowID
                == windowID
        }) else {
            return nil
        }
        return await captureAppKitWindowPNGData(window)
    }

    private func captureAppKitWindowPNGData(_ window: NSWindow) async -> WindowAppKitCapture? {
        guard !Task.isCancelled else { return nil }
        // Every WebKit request consumes from one aggregate fallback budget so
        // this independently leased backend responds promptly to cancellation.
        let captureDeadline = ProcessInfo.processInfo.systemUptime + 4
        guard let captureRoot = WindowAppKitCapture.rootView(for: window) else {
            return nil
        }

        let bounds = captureRoot.bounds
        guard !bounds.isEmpty,
              let bitmap = captureRoot.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        bitmap.size = bounds.size

        captureRoot.displayIfNeeded()
        captureRoot.cacheDisplay(in: bounds, to: bitmap)
        guard !Task.isCancelled else { return nil }

        var overlays: [WindowScreenshotOverlay] = []
        var capturedOccludingViews = Set<ObjectIdentifier>()

        for terminalView in visibleDescendants(of: captureRoot, as: GhosttySurfaceScrollView.self) {
            guard !Task.isCancelled else { return nil }
            guard let clipRect = WindowAppKitCapture.visibleRect(
                of: terminalView.surfaceView,
                through: captureRoot
            ) else {
                continue
            }
            guard let image = terminalView.debugCopyIOSurfaceCGImage() else {
                continue
            }
            let rect = terminalView.surfaceView.convert(
                terminalView.surfaceView.bounds,
                to: captureRoot
            )
            guard !rect.isEmpty else { continue }
            let alpha = effectiveAlpha(of: terminalView.surfaceView, through: captureRoot)
            guard alpha > 0 else { continue }
            guard let zOrder = hierarchyZOrder(of: terminalView.surfaceView, through: captureRoot) else {
                continue
            }
            overlays.append(WindowScreenshotOverlay(
                image: image,
                rect: rect,
                clipRect: clipRect,
                alpha: alpha,
                zOrder: zOrder
            ))
            appendNativeDescendantOverlays(
                inside: terminalView.surfaceView,
                through: captureRoot,
                capturedViews: &capturedOccludingViews,
                to: &overlays
            )
            appendNativeOccluderOverlays(
                above: terminalView.surfaceView,
                through: captureRoot,
                overlapping: rect,
                capturedViews: &capturedOccludingViews,
                to: &overlays
            )
        }

        for webView in visibleDescendants(of: captureRoot, as: WKWebView.self) {
            guard !Task.isCancelled else { return nil }
            guard let clipRect = WindowAppKitCapture.visibleRect(
                of: webView,
                through: captureRoot
            ) else {
                continue
            }
            let remainingBudget =
                captureDeadline - ProcessInfo.processInfo.systemUptime
            guard remainingBudget > 0 else { break }
            do {
                let image = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                    from: webView,
                    timeout: min(2, remainingBudget)
                )
                guard !Task.isCancelled else { return nil }
                var proposedRect = NSRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(
                    forProposedRect: &proposedRect,
                    context: nil,
                    hints: nil
                ) else {
                    continue
                }
                let rect = webView.convert(webView.bounds, to: captureRoot)
                guard !rect.isEmpty else { continue }
                let alpha = effectiveAlpha(of: webView, through: captureRoot)
                guard alpha > 0 else { continue }
                guard let zOrder = hierarchyZOrder(of: webView, through: captureRoot) else {
                    continue
                }
                overlays.append(WindowScreenshotOverlay(
                    image: cgImage,
                    rect: rect,
                    clipRect: clipRect,
                    alpha: alpha,
                    zOrder: zOrder
                ))
                for overlayView in WindowAppKitCapture.ownedNativeOverlayCandidates(
                    inside: webView
                ) {
                    appendNativeOverlay(
                        overlayView,
                        through: captureRoot,
                        capturedViews: &capturedOccludingViews,
                        to: &overlays
                    )
                }
                appendNativeOccluderOverlays(
                    above: webView,
                    through: captureRoot,
                    overlapping: rect,
                    capturedViews: &capturedOccludingViews,
                    to: &overlays
                )
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }

        guard !Task.isCancelled else { return nil }
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        let context = graphicsContext.cgContext
        context.saveGState()
        context.interpolationQuality = .high
        context.clip(
            to: NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: bounds.height
            )
        )
        for overlay in overlays.sorted(by: { hierarchyZOrderPrecedes($0.zOrder, $1.zOrder) }) {
            guard overlay.clipRect.intersects(bounds) else { continue }
            context.saveGState()
            context.setAlpha(overlay.alpha)
            let destinationRect = windowScreenshotBitmapRect(
                for: overlay.rect,
                within: bounds,
                sourceIsFlipped: captureRoot.isFlipped
            )
            let destinationClipRect = windowScreenshotBitmapRect(
                for: overlay.clipRect,
                within: bounds,
                sourceIsFlipped: captureRoot.isFlipped
            )
            context.clip(to: destinationClipRect)
            context.draw(overlay.image, in: destinationRect)
            context.restoreGState()
        }
        context.restoreGState()

        guard !Task.isCancelled else { return nil }
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return WindowAppKitCapture(pngData: pngData)
    }

    private func visibleDescendants<T: NSView>(
        of root: NSView,
        as type: T.Type
    ) -> [T] {
        var matches: [T] = []
        var pending = root.subviews
        while let view = pending.popLast() {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else {
                continue
            }
            if let match = view as? T {
                matches.append(match)
                continue
            }
            pending.append(contentsOf: view.subviews)
        }
        return matches
    }

    private func appendNativeDescendantOverlays(
        inside externalView: NSView,
        through root: NSView,
        capturedViews: inout Set<ObjectIdentifier>,
        to overlays: inout [WindowScreenshotOverlay]
    ) {
        for subview in WindowAppKitCapture.nativeOverlayCandidates(
            inside: externalView
        ) {
            appendNativeOverlay(
                subview,
                through: root,
                capturedViews: &capturedViews,
                to: &overlays
            )
        }
    }

    private func appendNativeOccluderOverlays(
        above externalView: NSView,
        through root: NSView,
        overlapping externalRect: NSRect,
        capturedViews: inout Set<ObjectIdentifier>,
        to overlays: inout [WindowScreenshotOverlay]
    ) {
        var current = externalView

        while current !== root {
            guard let parent = current.superview,
                  let index = parent.subviews.firstIndex(where: { $0 === current }) else {
                return
            }

            for sibling in parent.subviews.dropFirst(index + 1) {
                let rect = sibling.convert(sibling.bounds, to: root)
                guard !rect.isEmpty, rect.intersects(externalRect) else { continue }
                appendNativeOverlay(
                    sibling,
                    through: root,
                    capturedViews: &capturedViews,
                    to: &overlays
                )
            }
            current = parent
        }
    }

    private func appendNativeOverlay(
        _ view: NSView,
        through root: NSView,
        capturedViews: inout Set<ObjectIdentifier>,
        to overlays: inout [WindowScreenshotOverlay]
    ) {
        guard !view.isHiddenOrHasHiddenAncestor,
              view.alphaValue > 0,
              !WindowAppKitCapture.containsSystemCompositorContent(in: view),
              let clipRect = WindowAppKitCapture.visibleRect(of: view, through: root) else {
            return
        }
        let identifier = ObjectIdentifier(view)
        guard capturedViews.insert(identifier).inserted,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        bitmap.size = view.bounds.size
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return }
        let rect = view.convert(view.bounds, to: root)
        let alpha = effectiveAlpha(of: view, through: root)
        guard !rect.isEmpty,
              alpha > 0,
              let zOrder = hierarchyZOrder(of: view, through: root) else {
            return
        }
        overlays.append(WindowScreenshotOverlay(
            image: image,
            rect: rect,
            clipRect: clipRect,
            alpha: alpha,
            zOrder: zOrder
        ))
    }

    private func windowScreenshotBitmapRect(
        for rect: NSRect,
        within bounds: NSRect,
        sourceIsFlipped: Bool
    ) -> NSRect {
        if sourceIsFlipped {
            return NSRect(
                x: rect.minX - bounds.minX,
                y: bounds.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
        return NSRect(
            x: rect.minX - bounds.minX,
            y: rect.minY - bounds.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private func hierarchyZOrder(of view: NSView, through root: NSView) -> [Int]? {
        var reversedPath: [Int] = []
        var current = view
        while current !== root {
            guard let parent = current.superview,
                  let index = parent.subviews.firstIndex(where: { $0 === current }) else {
                return nil
            }
            reversedPath.append(index)
            current = parent
        }
        return Array(reversedPath.reversed())
    }

    private func hierarchyZOrderPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }

    private func effectiveAlpha(of view: NSView, through root: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var current: NSView? = view
        while let candidate = current {
            alpha *= candidate.alphaValue
            if candidate === root {
                return alpha
            }
            current = candidate.superview
        }
        return 0
    }
}
#endif

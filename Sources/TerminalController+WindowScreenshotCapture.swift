import AppKit
import CmuxFoundation
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

        let captureCoordinator = windowScreenshotCaptureCoordinator
        guard let admission = captureCoordinator.claim() else {
            return "ERROR: screenshot capture already in progress"
        }

        defer {
            captureCoordinator.finish(admission)
        }

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

            guard let window,
                  let windowID = WindowScreenshotTarget(
                    windowNumber: window.windowNumber
                  )?.windowID else {
                return nil
            }
            return windowID
        }

        guard let captureTarget else {
            return "ERROR: No window available"
        }

        // AppKit does not include every layer-backed child in cacheDisplay.
        // The permission-free capture above fills those gaps from cmux's own
        // Ghostty IOSurfaces and WKWebView snapshots. Only ask the system
        // compositor when one of those own-process snapshots was unavailable,
        // and retain the AppKit result as the no-permission fallback.
        let appKitCapture = captureAppKitWindowPNGData(captureTarget)
        let pngData: Data
        if let appKitCapture, appKitCapture.capturedAllExternalContent {
            pngData = appKitCapture.pngData
        } else {
            let screenCaptureKitAttempt = captureScreenCaptureKitWindowPNGData(
                captureTarget,
                isAllowed: admission.allowsScreenCaptureKit
            )
            switch screenCaptureKitAttempt {
            case .captured(let data):
                pngData = data
            case .unavailable:
                guard let appKitCapture else {
                    return "ERROR: Failed to create PNG data"
                }
                pngData = appKitCapture.pngData
            case .timedOut:
                return "ERROR: screenshot capture timed out"
            }
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
        _ windowID: CGWindowID,
        isAllowed: Bool
    ) -> WindowScreenshotCaptureAttempt {
        guard isAllowed else {
            return .timedOut
        }

        let captureTask = Task {
            return await Self.captureScreenCaptureKitWindowPNGDataAsync(windowID)
        }
        let captured: Data?? = socketAwaitCallback(timeout: 5) { completion in
            Task {
                completion(await captureTask.value)
            }
        }
        guard let captured else {
            windowScreenshotCaptureCoordinator
                .disableScreenCaptureKitUntilAttemptRetires()
            captureTask.cancel()
            let captureCoordinator = windowScreenshotCaptureCoordinator
            Task {
                _ = await captureTask.value
                captureCoordinator.screenCaptureKitAttemptDidRetire()
            }
            return .timedOut
        }
        guard let captured else {
            return .unavailable
        }
        return .captured(captured)
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
    ) -> WindowAppKitCapture? {
        let deliveryIsOpen = AtomicBooleanGate(true)
        var captureTask: Task<Void, Never>?
        let capture: WindowAppKitCapture?? = socketAwaitCallback(timeout: 5) { completion in
            captureTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                guard let window = NSApp.windows.first(where: {
                    guard let candidateID = WindowScreenshotTarget(
                        windowNumber: $0.windowNumber
                    )?.windowID else {
                        return false
                    }
                    return candidateID == windowID
                }) else {
                    if deliveryIsOpen.compareExchange(expected: true, desired: false) {
                        completion(nil)
                    }
                    return
                }
                let result = await self.captureAppKitWindowPNGData(window)
                guard !Task.isCancelled else { return }
                if deliveryIsOpen.compareExchange(expected: true, desired: false) {
                    completion(result)
                }
            }
        }
        if capture == nil {
            _ = deliveryIsOpen.compareExchange(expected: true, desired: false)
            captureTask?.cancel()
        }
        return capture ?? nil
    }

    private func captureAppKitWindowPNGData(_ window: NSWindow) async -> WindowAppKitCapture? {
        guard !Task.isCancelled else { return nil }
        // Leave enough time for drawing, PNG encoding, and delivery before the
        // worker's five-second waiter expires. Every WebKit request consumes
        // from this one aggregate budget instead of receiving two fresh seconds.
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

        var overlays: [(
            image: CGImage,
            rect: NSRect,
            clipRect: NSRect,
            alpha: CGFloat,
            zOrder: [Int]
        )] = []
        var capturedOccludingViews = Set<ObjectIdentifier>()
        var capturedAllExternalContent = true

        for terminalView in visibleDescendants(of: captureRoot, as: GhosttySurfaceScrollView.self) {
            guard !Task.isCancelled else { return nil }
            guard let clipRect = WindowAppKitCapture.visibleRect(
                of: terminalView.surfaceView,
                through: captureRoot
            ) else {
                continue
            }
            guard let image = terminalView.debugCopyIOSurfaceCGImage() else {
                capturedAllExternalContent = false
                continue
            }
            let rect = terminalView.surfaceView.convert(
                terminalView.surfaceView.bounds,
                to: captureRoot
            )
            guard !rect.isEmpty else {
                capturedAllExternalContent = false
                continue
            }
            let alpha = effectiveAlpha(of: terminalView.surfaceView, through: captureRoot)
            guard alpha > 0 else { continue }
            guard let zOrder = hierarchyZOrder(of: terminalView.surfaceView, through: captureRoot) else {
                capturedAllExternalContent = false
                continue
            }
            overlays.append((image, rect, clipRect, alpha, zOrder))
            if !appendNativeOccluderOverlays(
                above: terminalView.surfaceView,
                through: captureRoot,
                overlapping: rect,
                capturedViews: &capturedOccludingViews,
                to: &overlays
            ) {
                capturedAllExternalContent = false
            }
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
            guard remainingBudget > 0 else {
                capturedAllExternalContent = false
                break
            }
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
                    capturedAllExternalContent = false
                    continue
                }
                let rect = webView.convert(webView.bounds, to: captureRoot)
                guard !rect.isEmpty else {
                    capturedAllExternalContent = false
                    continue
                }
                let alpha = effectiveAlpha(of: webView, through: captureRoot)
                guard alpha > 0 else { continue }
                guard let zOrder = hierarchyZOrder(of: webView, through: captureRoot) else {
                    capturedAllExternalContent = false
                    continue
                }
                overlays.append((cgImage, rect, clipRect, alpha, zOrder))
                if !appendNativeOccluderOverlays(
                    above: webView,
                    through: captureRoot,
                    overlapping: rect,
                    capturedViews: &capturedOccludingViews,
                    to: &overlays
                ) {
                    capturedAllExternalContent = false
                }
            } catch is CancellationError {
                return nil
            } catch {
                capturedAllExternalContent = false
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
        return WindowAppKitCapture(
            pngData: pngData,
            capturedAllExternalContent: capturedAllExternalContent
        )
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

    private func appendNativeOccluderOverlays(
        above externalView: NSView,
        through root: NSView,
        overlapping externalRect: NSRect,
        capturedViews: inout Set<ObjectIdentifier>,
        to overlays: inout [(
            image: CGImage,
            rect: NSRect,
            clipRect: NSRect,
            alpha: CGFloat,
            zOrder: [Int]
        )]
    ) -> Bool {
        var capturedEveryOccluder = true
        var current = externalView

        while current !== root {
            guard let parent = current.superview,
                  let index = parent.subviews.firstIndex(where: { $0 === current }) else {
                return false
            }

            for sibling in parent.subviews.dropFirst(index + 1) {
                guard !sibling.isHiddenOrHasHiddenAncestor,
                      sibling.alphaValue > 0,
                      !viewHierarchyContainsExternalContent(sibling) else {
                    continue
                }
                let rect = sibling.convert(sibling.bounds, to: root)
                guard !rect.isEmpty, rect.intersects(externalRect) else { continue }
                guard let clipRect = WindowAppKitCapture.visibleRect(
                    of: sibling,
                    through: root
                ) else {
                    continue
                }

                let identifier = ObjectIdentifier(sibling)
                guard capturedViews.insert(identifier).inserted else { continue }
                guard let bitmap = sibling.bitmapImageRepForCachingDisplay(in: sibling.bounds) else {
                    capturedEveryOccluder = false
                    continue
                }
                bitmap.size = sibling.bounds.size
                sibling.displayIfNeeded()
                sibling.cacheDisplay(in: sibling.bounds, to: bitmap)
                guard let image = bitmap.cgImage else {
                    capturedEveryOccluder = false
                    continue
                }
                let alpha = effectiveAlpha(of: sibling, through: root)
                guard alpha > 0 else { continue }
                guard let zOrder = hierarchyZOrder(of: sibling, through: root) else {
                    capturedEveryOccluder = false
                    continue
                }
                overlays.append((image, rect, clipRect, alpha, zOrder))
            }
            current = parent
        }

        return capturedEveryOccluder
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

    private func viewHierarchyContainsExternalContent(_ view: NSView) -> Bool {
        if view is GhosttyNSView || view is WKWebView {
            return true
        }
        return view.subviews.contains(where: viewHierarchyContainsExternalContent)
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

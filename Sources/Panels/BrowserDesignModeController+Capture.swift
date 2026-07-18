import AppKit
import CmuxBrowser
import Foundation
import WebKit

extension BrowserDesignModeController {
    /// Starts the synchronous ink lifecycle before any capture work exists.
    func beginAnnotationDrawing(id: String) {
        guard phase.isEnabled, interactionMode == .draw, !id.isEmpty else { return }
        switch phase.annotation {
        case .idle, .captured:
            break
        case .drawing, .inkOnly, .capturing, nil:
            return
        }
        phase = .active(annotation: .drawing(id: id))
        errorMessage = nil
    }

    /// Returns an abandoned sub-threshold stroke to the normal active phase.
    func cancelAnnotationDrawing(id: String) {
        guard phase.isEnabled else { return }
        switch phase.annotation {
        case .drawing(let activeID) where activeID == id:
            phase = .active(annotation: .idle)
        case .inkOnly(let request) where request.id == id,
             .capturing(let request) where request.id == id:
            annotationCaptureTask?.cancel()
            annotationCaptureTask = nil
            annotationCaptureTaskID = nil
            screenshotEvaluator.cancelAll()
            phase = .active(annotation: .idle)
        default:
            break
        }
    }

    /// Accepts the completed ink descriptor and begins capture on the next task turn.
    func receiveAnnotationCaptureRequestData(_ data: Data) {
        guard phase.isEnabled,
              let request = try? JSONDecoder().decode(
                  BrowserDesignModeAnnotationCaptureRequest.self,
                  from: data
              ), !request.id.isEmpty else { return }
        guard interactionMode == .draw,
              case .drawing(let activeID)? = phase.annotation,
              activeID == request.id else {
            if let webView {
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    await self.cancelAnnotationCapture(id: request.id, in: webView, reportError: false)
                }
            }
            return
        }
        phase = .active(annotation: .inkOnly(request))
        annotationCaptureTask?.cancel()
        let taskID = UUID()
        annotationCaptureTaskID = taskID
        annotationCaptureTask = Task { @MainActor [weak self] in
            await self?.captureAnnotation(request, taskID: taskID)
        }
    }

    func captureStableSelection(
        in webView: WKWebView
    ) async throws -> (snapshot: BrowserDesignModeSnapshot, image: NSImage, viewBounds: NSRect) {
        let visibleImage = try await screenshotEvaluator.captureVisibleViewport(from: webView)
        let captureShield = BrowserDesignModeCaptureShield.install(image: visibleImage, over: webView)
        defer { captureShield?.remove() }

        for _ in 0..<2 {
            let candidate = try await captureSelectionCandidate(in: webView)
            if BrowserDesignModeSupport.captureMatches(
                before: candidate.before,
                after: candidate.after,
                beforeViewBounds: candidate.beforeViewBounds,
                afterViewBounds: candidate.afterViewBounds
            ) {
                return (candidate.after, candidate.image, candidate.afterViewBounds)
            }
        }
        throw BrowserDesignModeError.captureChanged
    }

    private func captureAnnotation(
        _ request: BrowserDesignModeAnnotationCaptureRequest,
        taskID: UUID
    ) async {
        defer {
            if annotationCaptureTaskID == taskID {
                annotationCaptureTask = nil
                annotationCaptureTaskID = nil
            }
        }
        guard phase.annotation == .inkOnly(request), let webView else { return }
        phase = .active(annotation: .capturing(request))
        let operation = operationRevision
        var unregisteredScreenshotURL: URL?
        do {
            let capture = try await captureStableAnnotation(id: request.id, in: webView)
            guard operation == operationRevision else { return }
            let crop = try BrowserScreenshotCrop.croppedImage(
                from: capture.image,
                selectionInView: BrowserDesignModeSupport.captureRect(
                    selection: capture.contextRect,
                    viewport: capture.descriptor.viewport,
                    viewBounds: capture.viewBounds
                ),
                viewBounds: capture.viewBounds
            )
            let pngData = try BrowserScreenshotPasteboardWriter.pngData(for: crop)
            let screenshotURL = try await screenshotStore.save(
                pngData,
                surfaceID: surfaceID,
                retention: .liveContext
            )
            unregisteredScreenshotURL = screenshotURL
            guard operation == operationRevision else {
                await screenshotStore.remove(screenshotURL)
                return
            }
            let value = try await evaluate(
                """
                return globalThis.__cmuxDesignMode?.completeAnnotationCapture(
                    id, x, y, width, height, imageURL,
                    scrollX, scrollY, viewportWidth, viewportHeight
                );
                """,
                arguments: [
                    "id": request.id,
                    "x": capture.contextRect.x,
                    "y": capture.contextRect.y,
                    "width": capture.contextRect.width,
                    "height": capture.contextRect.height,
                    "imageURL": "data:image/png;base64,\(pngData.base64EncodedString())",
                    "scrollX": capture.descriptor.scrollX,
                    "scrollY": capture.descriptor.scrollY,
                    "viewportWidth": capture.descriptor.viewport.width,
                    "viewportHeight": capture.descriptor.viewport.height,
                ],
                in: webView
            )
            guard operation == operationRevision else {
                await screenshotStore.remove(screenshotURL)
                return
            }
            let next = try BrowserDesignModeSupport.decodeSnapshot(value)
            let selector = "@annotation(\(request.id))"
            annotationScreenshotPaths[selector] = screenshotURL.path
            unregisteredScreenshotURL = nil
            apply(next)
            phase = .active(annotation: .captured(id: request.id, selector: selector))
            errorMessage = nil
            isComposerPresented = true
        } catch is CancellationError {
            if let unregisteredScreenshotURL {
                await screenshotStore.remove(unregisteredScreenshotURL)
            }
            await cancelAnnotationCapture(id: request.id, in: webView, reportError: false)
        } catch {
            if let unregisteredScreenshotURL {
                await screenshotStore.remove(unregisteredScreenshotURL)
            }
            BrowserDesignModeSupport.record(error, operation: "annotationCapture")
            await cancelAnnotationCapture(id: request.id, in: webView, reportError: true)
        }
    }

    private func captureStableAnnotation(
        id: String,
        in webView: WKWebView
    ) async throws -> (
        descriptor: BrowserDesignModeAnnotationCaptureRequest,
        contextRect: BrowserDesignModeRect,
        image: NSImage,
        viewBounds: NSRect
    ) {
        let geometry = BrowserDesignModeAnnotationCapture(contextPadding: 48)
        for _ in 0..<2 {
            let prepared = try await evaluate(
                "return globalThis.__cmuxDesignMode?.prepareAnnotationCapture(id);",
                arguments: ["id": id],
                in: webView
            )
            let before = try BrowserDesignModeSupport.decodeAnnotationCaptureRequest(prepared)
            let contextRect = geometry.contextRect(around: before.strokeBounds, in: before.viewport)
            guard contextRect.width > 0, contextRect.height > 0 else {
                throw BrowserScreenshotError.invalidSelection
            }
            let beforeViewBounds = webView.bounds
            let image = try await screenshotEvaluator.captureVisibleViewport(from: webView)
            let after = try BrowserDesignModeSupport.decodeAnnotationCaptureRequest(
                try await evaluate(
                    "return globalThis.__cmuxDesignMode?.annotationCaptureDescriptor(id);",
                    arguments: ["id": id],
                    in: webView
                )
            )
            let afterViewBounds = webView.bounds
            if before == after, beforeViewBounds == afterViewBounds {
                return (after, contextRect, image, afterViewBounds)
            }
        }
        throw BrowserDesignModeError.captureChanged
    }

    private func captureSelectionCandidate(
        in webView: WKWebView
    ) async throws -> (
        before: BrowserDesignModeSnapshot,
        after: BrowserDesignModeSnapshot,
        image: NSImage,
        beforeViewBounds: NSRect,
        afterViewBounds: NSRect
    ) {
        do {
            let prepared = try await evaluate("return globalThis.__cmuxDesignMode?.prepareCapture();", in: webView)
            let before = try BrowserDesignModeSupport.decodeSnapshot(prepared)
            let beforeViewBounds = webView.bounds
            let image = try await screenshotEvaluator.captureVisibleViewport(from: webView)
            let after = try BrowserDesignModeSupport.decodeSnapshot(
                try await evaluate("return globalThis.__cmuxDesignMode?.snapshot();", in: webView)
            )
            let afterViewBounds = webView.bounds
            try await restoreCapturePresentation(in: webView)
            return (before, after, image, beforeViewBounds, afterViewBounds)
        } catch {
            // Run cleanup in a fresh task so cancellation of the capture task
            // cannot strand the page runtime with its overlays hidden.
            let cleanup = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                _ = try? await self.evaluate(
                    "return globalThis.__cmuxDesignMode?.finishCapture();",
                    in: webView
                )
                _ = try? await self.screenshotEvaluator.captureVisibleViewport(from: webView)
            }
            await cleanup.value
            throw error
        }
    }

    private func restoreCapturePresentation(in webView: WKWebView) async throws {
        _ = try await evaluate(
            "return globalThis.__cmuxDesignMode?.finishCapture();",
            in: webView
        )
        // `afterScreenUpdates` makes this callback the paint-completion signal;
        // the image is intentionally discarded while the native shield remains visible.
        _ = try await screenshotEvaluator.captureVisibleViewport(from: webView)
    }

    private func cancelAnnotationCapture(
        id: String,
        in webView: WKWebView,
        reportError: Bool
    ) async {
        _ = try? await evaluate(
            "return globalThis.__cmuxDesignMode?.cancelAnnotationCapture(id);",
            arguments: ["id": id],
            in: webView
        )
        guard phase.isEnabled, phase.annotation?.id == id else { return }
        phase = .active(annotation: .idle)
        if reportError {
            errorMessage = String(
                localized: "browser.designMode.error.annotationCapture",
                defaultValue: "Could not capture the annotation. Draw it again."
            )
            isComposerPresented = true
        }
    }
}

private extension BrowserDesignModeAnnotationPhase {
    var id: String? {
        switch self {
        case .idle: nil
        case .drawing(let id), .captured(let id, _): id
        case .inkOnly(let request), .capturing(let request): request.id
        }
    }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@MainActor
@Suite(.serialized)
struct BrowserDesignModeScriptTests {
    @Test func loadsBundledRuntimeResource() async throws {
        let source = try await BrowserDesignModeScript().source()

        #expect(!source.isEmpty)
    }

    @Test func missingRuntimeResourceThrowsWithoutTerminatingProcess() async {
        let script = BrowserDesignModeScript(resourceURL: nil)

        await #expect(throws: CocoaError.self) {
            try await script.source()
        }
    }

    @Test func completedAnnotationKeepsFreehandInkVisibleInsideOutlinedRegion() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeScriptNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <style>
              html, body { margin: 0; width: 640px; height: 900px; background: white; }
            </style>
            """,
            baseURL: nil
        )
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        _ = try await webView.evaluateJavaScript(BrowserDesignModeScript().source())
        _ = try await webView.evaluateJavaScript(
            """
            const runtime = globalThis.__cmuxDesignMode;
            runtime.enable();
            runtime.setMode('draw');
            const event = (type, x, y) => document.dispatchEvent(new PointerEvent(type, {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                buttons: type === 'pointerup' ? 0 : 1,
                clientX: x,
                clientY: y,
            }));
            event('pointerdown', 140, 240);
            event('pointermove', 200, 240);
            event('pointermove', 260, 240);
            event('pointerup', 320, 240);
            const descriptor = runtime.annotationCaptureDescriptor('1');
            const bounds = descriptor.stroke_bounds;
            runtime.completeAnnotationCapture(
                descriptor.id,
                bounds.x - 48,
                bounds.y - 48,
                bounds.width + 96,
                bounds.height + 96,
                descriptor.scroll_x,
                descriptor.scroll_y,
                descriptor.viewport.width,
                descriptor.viewport.height
            );
            """
        )

        let rendered = try await snapshot(of: webView)
        let bitmap = try #require(
            rendered.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        let scaleX = CGFloat(bitmap.pixelsWide) / rendered.size.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / rendered.size.height
        let centerX = Int(230 * scaleX)
        let centerY = Int(240 * scaleY)
        let radius = max(4, Int(12 * max(scaleX, scaleY)))
        var containsInk = false
        for y in max(0, centerY - radius)...min(bitmap.pixelsHigh - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(bitmap.pixelsWide - 1, centerX + radius) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.blueComponent > 0.7,
                   color.greenComponent > 0.3,
                   color.redComponent < 0.3 {
                    containsInk = true
                    break
                }
            }
            if containsInk { break }
        }

        #expect(containsInk, "Completed freehand ink must remain visible inside its dotted region")
        _ = navigationDelegate
    }

    private func snapshot(of webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: error ?? CocoaError(.fileReadUnknown)
                    )
                }
            }
        }
    }
}

@MainActor
private final class BrowserDesignModeScriptNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish()
    }
}

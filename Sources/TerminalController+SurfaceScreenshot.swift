import AppKit
import CmuxTerminal
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if DEBUG
/// `debug.surface.screenshot` — ground-truth capture of one terminal surface
/// without the window server.
///
/// Mechanism: the socket worker asks the surface for one forced tokened render
/// (`ghostty_surface_request_render_with_token`, cmux fork API). The renderer
/// thread rebuilds frame data from the current terminal state and draws it,
/// deliberately ignoring the occlusion gate; libghostty acknowledges the token
/// on the main thread in the same block that assigns the frame's IOSurface to
/// the layer. The waiter then deep-copies that IOSurface — the exact bytes the
/// compositor would composite for the terminal grid area — at native backing
/// resolution (2x on Retina), tagged Display P3 (the renderer's true target
/// color space; see `ghostty/src/renderer/metal/Target.zig`).
///
/// The path never activates the app, never changes key window, never reorders
/// windows, needs no Screen Recording permission, and works while the window
/// is fully occluded, on another Space, or never ordered front.
extension TerminalController {
    /// One captured presented frame plus the visibility evidence observed on
    /// the main thread at capture time (so callers can prove the capture
    /// happened while occluded and non-frontmost).
    private struct V2SurfaceScreenshotFrame: @unchecked Sendable {
        let surfaceId: UUID
        let image: CGImage
        let backingScale: CGFloat
        let windowOcclusionVisible: Bool
        let appActive: Bool
        let windowFrame: CGRect?
    }

    private enum V2SurfaceScreenshotOutcome: @unchecked Sendable {
        case frame(V2SurfaceScreenshotFrame)
        case failure(code: String, message: String)
    }

    nonisolated func v2DebugSurfaceScreenshot(params: [String: Any]) -> V2CallResult {
        let surfaceArg = ((params["surface_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surfaceArg.isEmpty else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let requestedScale: Double?
        if let raw = params["scale"] {
            guard let value = (raw as? Double) ?? (raw as? Int).map(Double.init),
                  value > 0, value <= 8 else {
                return .err(code: "invalid_params", message: "scale must be a number in (0, 8]", data: nil)
            }
            requestedScale = value
        } else {
            requestedScale = nil
        }
        let label = ((params["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitPath = ((params["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome: V2SurfaceScreenshotOutcome? = socketAwaitCallback(timeout: 10.0) { finish in
            v2MainSync {
                self.v2StartDebugSurfaceScreenshot(surfaceArg: surfaceArg, finish: finish)
            }
        }

        guard let outcome else {
            return .err(
                code: "timeout",
                message: "Timed out waiting for the renderer to present the requested frame",
                data: nil
            )
        }
        let frame: V2SurfaceScreenshotFrame
        switch outcome {
        case .failure(let code, let message):
            return .err(code: code, message: message, data: nil)
        case .frame(let value):
            frame = value
        }

        // Native capture by default; an explicit scale resamples in Display P3
        // (output pixels = logical points * scale, so scale==backingScale is
        // the native passthrough).
        let outputImage: CGImage
        let outputScale: Double
        if let requestedScale, abs(requestedScale - Double(frame.backingScale)) > 0.001 {
            let factor = requestedScale / Double(frame.backingScale)
            guard let scaled = Self.v2ResampleDisplayP3(frame.image, factor: factor) else {
                return .err(code: "internal_error", message: "Failed to resample capture", data: nil)
            }
            outputImage = scaled
            outputScale = requestedScale
        } else {
            outputImage = frame.image
            outputScale = Double(frame.backingScale)
        }

        let outputURL: URL
        if !explicitPath.isEmpty {
            outputURL = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
        } else {
            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-screenshots")
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortId = String(UUID().uuidString.prefix(8))
            let base = label.isEmpty ? "surface" : label
            outputURL = outputDir.appendingPathComponent("\(base)-\(timestampMs)-\(shortId).png")
        }

        guard Self.v2WritePNG(outputImage, to: outputURL) else {
            return .err(code: "internal_error", message: "Failed to encode or write PNG", data: nil)
        }

        var result: [String: Any] = [
            "surface_id": frame.surfaceId.uuidString,
            "path": outputURL.path,
            "width_px": outputImage.width,
            "height_px": outputImage.height,
            "points_width": Double(frame.image.width) / Double(frame.backingScale),
            "points_height": Double(frame.image.height) / Double(frame.backingScale),
            "scale": outputScale,
            "native_scale": Double(frame.backingScale),
            "color_space": "display-p3",
            "window_occlusion_visible": frame.windowOcclusionVisible,
            "app_active": frame.appActive,
        ]
        if let windowFrame = frame.windowFrame {
            result["window_frame"] = [
                "x": Double(windowFrame.origin.x),
                "y": Double(windowFrame.origin.y),
                "width": Double(windowFrame.width),
                "height": Double(windowFrame.height),
            ]
        }
        return .ok(result)
    }

    @MainActor
    private func v2StartDebugSurfaceScreenshot(
        surfaceArg: String,
        finish: @escaping (V2SurfaceScreenshotOutcome) -> Void
    ) {
        guard let tabManager else {
            finish(.failure(code: "unavailable", message: "TabManager not available"))
            return
        }
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            finish(.failure(code: "not_found", message: "No tab selected"))
            return
        }
        guard let panelId = resolveSurfaceId(from: surfaceArg, tab: tab),
              let terminalPanel = tab.terminalInputTarget(forPanelID: panelId)?.panel else {
            finish(.failure(code: "not_found", message: "Terminal surface not found"))
            return
        }

        let view = terminalPanel.hostedView
        let surface = terminalPanel.surface
        let capturedSurfaceId = panelId
        let token = TerminalSurface.makePresentedFrameToken()
        let accepted = surface.requestPresentedFrame(token: token) { [weak view] in
            guard let view,
                  let presented = view.debugCopyPresentedFrameImage() else {
                finish(.failure(
                    code: "internal_error",
                    message: "Failed to read the presented IOSurface"
                ))
                return
            }
            let window = view.window
            finish(.frame(V2SurfaceScreenshotFrame(
                surfaceId: capturedSurfaceId,
                image: presented.image,
                backingScale: presented.backingScale,
                windowOcclusionVisible: window?.occlusionState.contains(.visible) ?? false,
                appActive: NSApp.isActive,
                windowFrame: window?.frame
            )))
        }
        if !accepted {
            finish(.failure(
                code: "unavailable",
                message: "Tokened render unavailable (no live realized renderer, or another capture is pending)"
            ))
        }
    }

    /// Resamples in the capture's own color space so pixel values stay
    /// Display P3 and only resolution changes.
    private nonisolated static func v2ResampleDisplayP3(_ image: CGImage, factor: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Writes through ImageIO so the PNG embeds the image's Display P3 ICC
    /// profile (NSBitmapImageRep would re-tag through its own colorspace).
    private nonisolated static func v2WritePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
#endif

// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// A CGImage that may cross threads (immutable once made).
struct CapturedImage: @unchecked Sendable {
    let image: CGImage
}

enum CaptureError: Error, CustomStringConvertible {
    case windowNotFound(CGWindowID)
    case encodeFailed

    var description: String {
        switch self {
        case .windowNotFound(let id): "window \(id) is not shareable (closed, or Screen Recording is not granted)"
        case .encodeFailed: "the screenshot could not be encoded"
        }
    }
}

/// Window screenshots through ScreenCaptureKit. `SCShareableContent` is the
/// expensive part of a capture (a WindowServer round trip that lists every
/// window), so its windows are cached by id and listed again only when a
/// window is new or a cached one fails. The capture is asked for at its
/// final pixel size, so scaling happens in the capture, not after it.
final class WindowCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [CGWindowID: SCWindow] = [:]

    func capture(windowID: CGWindowID, pixelWidth: Int, pixelHeight: Int) async throws -> CapturedImage {
        do {
            return try await capture(try await window(windowID, refresh: false), pixelWidth, pixelHeight)
        } catch {
            // A stale cached window (closed and reopened, or moved Spaces): list again once.
            return try await capture(try await window(windowID, refresh: true), pixelWidth, pixelHeight)
        }
    }

    private func capture(_ window: SCWindow, _ width: Int, _ height: Int) async throws -> CapturedImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, width)
        config.height = max(1, height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image)
    }

    private func window(_ id: CGWindowID, refresh: Bool) async throws -> SCWindow {
        if !refresh, let cached = lock.withLock({ windows[id] }) { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        lock.withLock { windows = byID }
        guard let window = byID[id] else { throw CaptureError.windowNotFound(id) }
        return window
    }

    /// Pixels per point of the display that holds `point` (2 on Retina).
    static func scale(at point: CGPoint) -> CGFloat {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}

/// JPEG through ImageIO (hardware assisted on Apple silicon). PNG of the
/// same window is 5-10x the bytes and several times slower to encode.
struct JPEGEncoder: Sendable {
    var quality: Double = 0.8

    func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodeFailed }
        return data as Data
    }
}

/// How a window's points map to its screenshot's pixels.
struct ScreenshotGeometry: Sendable, Equatable {
    var windowFrame: CGRect
    /// Screenshot pixels per window point.
    var pixelsPerPoint: CGFloat
    var pixelWidth: Int
    var pixelHeight: Int

    /// Retina scale, capped so the long edge stays within `maxLongEdge`.
    init(windowFrame: CGRect, displayScale: CGFloat, maxLongEdge: Int) {
        self.windowFrame = windowFrame
        let longEdge = max(windowFrame.width, windowFrame.height) * displayScale
        let cap = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        pixelsPerPoint = displayScale * cap
        pixelWidth = Int((windowFrame.width * pixelsPerPoint).rounded())
        pixelHeight = Int((windowFrame.height * pixelsPerPoint).rounded())
    }

    /// A screenshot pixel as a global (top-left origin) point.
    func globalPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: windowFrame.minX + CGFloat(x) / pixelsPerPoint, y: windowFrame.minY + CGFloat(y) / pixelsPerPoint)
    }
}

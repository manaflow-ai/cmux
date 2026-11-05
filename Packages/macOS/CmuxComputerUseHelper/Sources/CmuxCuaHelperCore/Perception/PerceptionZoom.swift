// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The last screenshot of a window this connection was given: what a zoom
/// region and a click are measured against.
struct ScreenshotFrame: Equatable, Sendable {
    /// The delivered screenshot's size in pixels.
    let width: Int
    let height: Int
    /// The window's size in points when it was captured.
    let windowWidth: Double
    let windowHeight: Double

    /// Window points per screenshot pixel.
    var pointsPerPixel: Double { windowWidth / Double(width) }
}

/// A zoom image this helper made: maps a point in it back to the full screenshot.
struct ZoomMapping: Equatable, Sendable {
    /// The zoom image's top-left, in full-screenshot pixels.
    let originX: Double
    let originY: Double
    /// Full-screenshot pixels per zoom-image pixel (below 1: the zoom is sharper).
    let pixelsPerZoomPixel: Double

    func screenshotPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        (originX + x * pixelsPerZoomPixel, originY + y * pixelsPerZoomPixel)
    }
}

/// `zoom` as a second capture at native resolution: the region is captured
/// again by ScreenCaptureKit at the display's backing scale, instead of a
/// crop of the window capture scaled down to 500 px.
struct PerceptionZoom: Sendable {
    /// Longest edge of a zoom image: the model's image limit, so it is never
    /// downscaled again on the way in.
    static let maxLongEdge = 1568
    /// Padding on each side, as a share of the region (upstream's 20%).
    static let padding = 0.2

    struct Region: Equatable {
        /// The padded region in full-screenshot pixels, clamped to the screenshot.
        let pixels: CGRect
    }

    /// The padded, clamped region, from `x1,y1,x2,y2` or `x,y,width,height`.
    static func region(_ arguments: [String: Any], frame: ScreenshotFrame) -> Region? {
        func number(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }
        let corners: (Double, Double, Double, Double)?
        if let x1 = number("x1"), let y1 = number("y1"), let x2 = number("x2"), let y2 = number("y2") {
            corners = (x1, y1, x2, y2)
        } else if let x = number("x"), let y = number("y"), let w = number("width"), let h = number("height") {
            corners = (x, y, x + w, y + h)
        } else {
            corners = nil
        }
        guard let (x1, y1, x2, y2) = corners, x2 > x1, y2 > y1 else { return nil }
        let padX = (x2 - x1) * padding, padY = (y2 - y1) * padding
        let left = max(0, x1 - padX), top = max(0, y1 - padY)
        let right = min(Double(frame.width), x2 + padX), bottom = min(Double(frame.height), y2 + padY)
        guard right > left, bottom > top else { return nil }
        return Region(pixels: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    /// Captures `region` of window `windowID` at native resolution (capped at `maxLongEdge`).
    func capture(windowID: UInt32, region: Region, frame: ScreenshotFrame) async throws -> (CGImage, ZoomMapping) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ToolError("zoom: window \(windowID) is not capturable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let k = frame.pointsPerPixel
        let source = CGRect(x: region.pixels.minX * k, y: region.pixels.minY * k,
                            width: region.pixels.width * k, height: region.pixels.height * k)
        var width = source.width * scale, height = source.height * scale
        let longEdge = max(width, height)
        if longEdge > Double(Self.maxLongEdge) {
            width *= Double(Self.maxLongEdge) / longEdge
            height *= Double(Self.maxLongEdge) / longEdge
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = max(1, Int(width.rounded()))
        configuration.height = max(1, Int(height.rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let mapping = ZoomMapping(originX: region.pixels.minX, originY: region.pixels.minY,
                                  pixelsPerZoomPixel: region.pixels.width / Double(image.width))
        return (image, mapping)
    }
}

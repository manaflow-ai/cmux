public import Foundation

/// Bounds on what one `tab.screenshot` or `tab.pdf` may make the app
/// allocate. The caller chooses a clip, a full page, a paper size and
/// margins; the main actor renders them, so one oversized capture would
/// stall or exhaust memory for every session and the user's windows.
public struct BrowserReplCaptureLimits: Sendable {
    /// The most pixels a screenshot may have, and the most points WebKit
    /// may snapshot for it (its region scaled by the page's zoom): 2^25,
    /// a full page 2,048 CSS pixels wide and 16,384 tall. WebKit draws
    /// that snapshot at the screen's backing scale, so it can hold four
    /// times as many pixels (512 MiB at 4 bytes each).
    public static let maximumScreenshotPixels: CGFloat = 33_554_432

    /// The largest PDF paper edge, in points: 200 inches, the largest page
    /// a PDF describes without a user unit (A0 is 2,384 by 3,370).
    public static let maximumPaperEdge: CGFloat = 14_400

    public init() {}

    /// Throws `invalid` when a screenshot of `region` (CSS pixels) at `zoom`
    /// (WebKit's page zoom times magnification) is out of bounds.
    public func checkScreenshot(region: CGRect, zoom: CGFloat) throws {
        let values = [region.minX, region.minY, region.width, region.height, zoom]
        guard values.allSatisfy(\.isFinite), zoom > 0 else {
            throw BrowserReplDriverError(code: "invalid", message: "The screenshot region is not a finite rectangle")
        }
        let pixels = region.width * region.height
        let snapshot = pixels * zoom * zoom
        guard max(pixels, snapshot) <= Self.maximumScreenshotPixels else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "A screenshot of \(Int(region.width))x\(Int(region.height)) CSS pixels"
                    + (zoom == 1 ? "" : " at zoom \(zoom)")
                    + " is past the limit of \(Int(Self.maximumScreenshotPixels)) pixels; capture a smaller clip"
            )
        }
    }

    /// Throws `invalid` when a PDF on `paper` with `margins` (points) is out
    /// of bounds: an edge not above 0 or past ``maximumPaperEdge``, a
    /// margin below 0 or not finite, or margins that leave no page.
    public func checkPDF(paper: CGSize, margins: NSEdgeInsets) throws {
        for (name, edge) in [("width", paper.width), ("height", paper.height)] {
            guard edge.isFinite, edge > 0, edge <= Self.maximumPaperEdge else {
                throw BrowserReplDriverError(
                    code: "invalid",
                    message: "The PDF paper \(name) must be above 0 and at most \(Int(Self.maximumPaperEdge)) points (200in)"
                )
            }
        }
        let sides = [margins.top, margins.left, margins.bottom, margins.right]
        guard sides.allSatisfy({ $0.isFinite && $0 >= 0 }),
              margins.left + margins.right < paper.width,
              margins.top + margins.bottom < paper.height else {
            throw BrowserReplDriverError(code: "invalid", message: "The PDF margins must be 0 or more and leave room on the paper")
        }
    }
}

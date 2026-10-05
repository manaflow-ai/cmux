import AppKit
import CmuxBrowser
import UniformTypeIdentifiers
import WebKit

/// Screenshots and PDFs for the REPL driver.
@MainActor
enum BrowserReplCapture {
    /// Largest screenshot edge, in CSS pixels.
    static let maximumEdge: CGFloat = 16_384

    /// Captures the viewport, a clip of it, or the full page at one image
    /// pixel per CSS pixel (Playwright's `deviceScaleFactor: 1`).
    static func snapshot(webView: WKWebView, clip: [String: Any]?, fullPage: Bool) async throws -> CGImage {
        try await snapshotWithRegion(webView: webView, clip: clip, fullPage: fullPage).image
    }

    /// As ``snapshot(webView:clip:fullPage:)``, with the region the image
    /// shows in CSS pixels of the viewport (its top-left at the image's).
    static func snapshotWithRegion(webView: WKWebView, clip: [String: Any]?, fullPage: Bool) async throws -> (image: CGImage, region: CGRect) {
        let metrics = try? await webView.browserReplCallAsyncJavaScript(
            """
            const d = document.documentElement;
            const b = document.body;
            return [innerWidth, innerHeight,
              Math.max(d.scrollWidth, b ? b.scrollWidth : 0), Math.max(d.scrollHeight, b ? b.scrollHeight : 0),
              scrollX, scrollY];
            """,
            arguments: [:],
            in: nil,
            contentWorld: BrowserReplAgentWorld.world,
            userGesture: false
        ) as? [NSNumber]
        let values = (metrics ?? []).map { CGFloat($0.doubleValue) }
        let zoom = webView.pageZoom * webView.magnification
        let viewportWidth = values.count > 0 ? values[0] : webView.bounds.width / zoom
        let viewportHeight = values.count > 1 ? values[1] : webView.bounds.height / zoom

        // Region in CSS pixels relative to the viewport's top-left.
        var region = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
        if fullPage, values.count > 5 {
            region = CGRect(x: -values[4], y: -values[5], width: values[2], height: values[3])
        }
        if let clip {
            let x = (clip["x"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let y = (clip["y"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let width = (clip["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? viewportWidth
            let height = (clip["height"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? viewportHeight
            // Playwright clips in page coordinates for full-page shots.
            region = fullPage && values.count > 5
                ? CGRect(x: x - values[4], y: y - values[5], width: width, height: height)
                : CGRect(x: x, y: y, width: width, height: height)
        }
        region.size.width = min(max(1, region.width), maximumEdge)
        region.size.height = min(max(1, region.height), maximumEdge)
        try BrowserReplCaptureLimits().checkScreenshot(region: region, zoom: zoom)

        let configuration = WKSnapshotConfiguration()
        let viewRect = CGRect(
            x: region.minX * zoom,
            y: webView.isFlipped ? region.minY * zoom : webView.bounds.height - (region.maxY * zoom),
            width: region.width * zoom,
            height: region.height * zoom
        )
        configuration.rect = viewRect
        configuration.snapshotWidth = NSNumber(value: Double(viewRect.width))
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        return (try rasterize(image, width: Int(region.width.rounded()), height: Int(region.height.rounded())), region)
    }

    private static func rasterize(_ image: NSImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw WebKitBrowserReplDriver.error("invalid", "Could not allocate a \(width)x\(height) screenshot")
        }
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw WebKitBrowserReplDriver.error("invalid", "The page snapshot had no bitmap")
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw WebKitBrowserReplDriver.error("invalid", "Could not render the screenshot")
        }
        return result
    }

    /// Encodes as `png`, `jpeg` (quality 0-100) or `webp`.
    static func encode(_ image: CGImage, format: String, quality: Double?) throws -> Data {
        let type: UTType
        switch format {
        case "jpeg", "jpg": type = .jpeg
        case "webp": type = .webP
        default: type = .png
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw WebKitBrowserReplDriver.error("unsupported", "Screenshots in \(format) format are not supported")
        }
        var options: [CFString: Any] = [:]
        if type != .png {
            options[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, (quality ?? 80) / 100))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WebKitBrowserReplDriver.error("unsupported", "Could not encode the screenshot as \(format)")
        }
        return data as Data
    }

    // MARK: - PDF

    /// Paper sizes in points, as in Playwright's `page.pdf({ format })`.
    static func paperSize(format: String) -> CGSize? {
        let inch: CGFloat = 72
        let millimeter: CGFloat = 72 / 25.4
        switch format.lowercased() {
        case "letter": return CGSize(width: 8.5 * inch, height: 11 * inch)
        case "legal": return CGSize(width: 8.5 * inch, height: 14 * inch)
        case "tabloid": return CGSize(width: 11 * inch, height: 17 * inch)
        case "ledger": return CGSize(width: 17 * inch, height: 11 * inch)
        case "a0": return CGSize(width: 841 * millimeter, height: 1189 * millimeter)
        case "a1": return CGSize(width: 594 * millimeter, height: 841 * millimeter)
        case "a2": return CGSize(width: 420 * millimeter, height: 594 * millimeter)
        case "a3": return CGSize(width: 297 * millimeter, height: 420 * millimeter)
        case "a4": return CGSize(width: 210 * millimeter, height: 297 * millimeter)
        case "a5": return CGSize(width: 148 * millimeter, height: 210 * millimeter)
        case "a6": return CGSize(width: 105 * millimeter, height: 148 * millimeter)
        default: return nil
        }
    }

    /// A CSS length (`"8.5in"`, `"210mm"`, `"1cm"`, `"96px"` or a number of
    /// CSS pixels) in points.
    static func points(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) * 72 / 96 }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            return nil
        }
        let units: [(String, CGFloat)] = [("px", 72 / 96), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { CGFloat($0) * factor }
        }
        return Double(text).map { CGFloat($0) * 72 / 96 }
    }

    /// The paper and margins, in points, of a PDF with Playwright's
    /// `format`, `width`, `height`, `landscape` and `margin` options; throws
    /// `invalid` past ``BrowserReplCaptureLimits``.
    static func pdfLayout(options: [String: Any]) throws -> (paper: CGSize, margins: NSEdgeInsets) {
        var paper = (options["format"] as? String).flatMap(paperSize(format:)) ?? CGSize(width: 8.5 * 72, height: 11 * 72)
        if let width = points(options["width"]) { paper.width = width }
        if let height = points(options["height"]) { paper.height = height }
        if options["landscape"] as? Bool == true { paper = CGSize(width: paper.height, height: paper.width) }
        let margin = options["margin"] as? [String: Any] ?? [:]
        let margins = NSEdgeInsets(
            top: points(margin["top"]) ?? 0,
            left: points(margin["left"]) ?? 0,
            bottom: points(margin["bottom"]) ?? 0,
            right: points(margin["right"]) ?? 0
        )
        try BrowserReplCaptureLimits().checkPDF(paper: paper, margins: margins)
        return (paper, margins)
    }

    /// Prints the page to a paginated PDF with Playwright's `format`, `width`,
    /// `height`, `landscape`, `margin` and `printBackground` options, in a
    /// print session of its own offscreen window, never the web view's.
    static func printPDF(webView: WKWebView, options: [String: Any]) async throws -> Data {
        let layout = try pdfLayout(options: options)
        do {
            return try await BrowserReplPDFPrinter(
                paper: layout.paper,
                margins: layout.margins,
                printBackground: options["printBackground"] as? Bool ?? false
            ).pdf(of: webView)
        } catch is BrowserReplPDFPrinter.Failure {
            throw WebKitBrowserReplDriver.error("invalid", "Printing to PDF failed")
        }
    }

    /// Whether `cookie` goes with a request to `url` (`HTTPCookie.browserReplMatches`).
    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        cookie.browserReplMatches(url)
    }
}

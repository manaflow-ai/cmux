import AppKit
import CmuxNextBrowser
import Foundation
import WebKit

extension WebKitDriver {
    /// `{ base64, width, height }` of the viewport or a clip (CSS pixels),
    /// at the page's CSS scale, as Playwright screenshots at scale 1.
    func tabScreenshot(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let format = try params.optionalString("format") ?? "png"
        guard format == "png" || format == "jpeg" else {
            throw DriverError(.unsupported, "tab.screenshot: format \(format) is not supported by the WebKit driver")
        }
        let configuration = WKSnapshotConfiguration()
        let zoom = tab.webView.pageZoom * tab.webView.magnification
        let scale = zoom > 0 ? zoom : 1
        // The clip is CSS pixels; the snapshot rect is view points.
        if try params.bool("fullPage") {
            // The whole document: its size and the scroll offset put the
            // rect over content outside the visible area (WebKit renders it).
            let size = try await run("""
            const d = document.documentElement, b = document.body;
            return [Math.max(d.scrollWidth, b ? b.scrollWidth : 0, innerWidth), Math.max(d.scrollHeight, b ? b.scrollHeight : 0, innerHeight), scrollX, scrollY];
            """, [:], nil, AgentWorld.hostWorld, tab)
            guard case .array(let values) = size, values.count == 4, case .number(let width) = values[0], case .number(let height) = values[1],
                  case .number(let x) = values[2], case .number(let y) = values[3] else {
                throw DriverError(.unsupported, "tab.screenshot: the page size could not be read")
            }
            configuration.rect = CGRect(x: -x * scale, y: -y * scale, width: width * scale, height: height * scale)
            configuration.snapshotWidth = NSNumber(value: width)
        } else if case .object(let clip) = params["clip"] ?? .null {
            let css = CGRect(x: clip["x"]?.numberValue ?? 0, y: clip["y"]?.numberValue ?? 0,
                             width: clip["width"]?.numberValue ?? 0, height: clip["height"]?.numberValue ?? 0)
            configuration.rect = CGRect(x: css.minX * scale, y: css.minY * scale, width: css.width * scale, height: css.height * scale)
            configuration.snapshotWidth = NSNumber(value: Double(css.width))
        } else {
            configuration.snapshotWidth = NSNumber(value: Double(tab.webView.bounds.width / scale))
        }
        let image: NSImage
        do {
            image = try await tab.webView.takeSnapshot(configuration: configuration)
        } catch {
            throw DriverError(.unsupported, "tab.screenshot: \(error.localizedDescription)")
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DriverError(.unsupported, "tab.screenshot: WebKit returned no image")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let jpeg = format == "jpeg"
        let quality = (try params.optionalNumber("quality") ?? 80) / 100
        guard let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
            : rep.representation(using: .png, properties: [:]) else {
            throw DriverError(.unsupported, "tab.screenshot: could not encode the image")
        }
        return .object(["base64": .string(data.base64EncodedString()), "width": .number(Double(cgImage.width)),
                        "height": .number(Double(cgImage.height))])
    }

    /// The page as PDF (`WKWebView.createPDF`): the visible layout, one page
    /// per paginated rect is UNVERIFIED (WebKit renders one tall page).
    func tabPDF(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        do {
            let data = try await tab.webView.pdf(configuration: WKPDFConfiguration())
            return .object(["base64": .string(data.base64EncodedString())])
        } catch {
            throw DriverError(.unsupported, "tab.pdf: \(error.localizedDescription)")
        }
    }
}

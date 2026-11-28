import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why the host refused or failed a reply link request. The page reads the code.
public nonisolated enum AgentPaneReplyError: String, Error, Equatable, Sendable {
    /// No real user gesture before an action that needs one.
    case gestureRequired = "link.gesture_required"
    /// A path on the deny list (keys, `.env`, `~/.ssh`).
    case pathDenied = "link.path_denied"
    /// A path outside the session's folders that the setting does not open.
    case pathOutsideRoots = "link.path_outside_roots"
    /// The user did not confirm an open outside the project.
    case notConfirmed = "link.not_confirmed"
    /// Not a path, nothing there, or the app could not open it.
    case pathInvalid = "link.path_invalid"
    /// `agentPane.images.remote` is `never`, or the URL or an address breaks the network rules.
    case imageRefused = "link.image_refused"
    case imageTooLarge = "link.image_too_large"
    /// The transfer failed, or the bytes are not an image the pane shows.
    case imageFailed = "link.image_failed"
    /// Not a local video or audio file the pane plays (``AgentPaneMediaGrants``).
    case mediaRefused = "link.media_refused"
    /// A browser id the last `browser.list` did not give.
    case browserUnknown = "link.browser_unknown"
    case openFailed = "link.open_failed"
}

/// Reply images as the page may draw them (decision D5): a `data:` URL, because the page's CSP
/// loads no other image. A local file must be inside the session's folders and at most
/// ``maximumBytes``; a raster image is decoded first, so bytes that only claim to be an image
/// never reach the page; an SVG is rebuilt without script, event handlers, foreign content or
/// links out (``AgentPaneSVGSanitizer``). A web image is always decoded and re-encoded as PNG. A PDF
/// shows as its first page, drawn as a PNG thumbnail (``pdfThumbnail(_:)``): the page never gets
/// the document.
nonisolated struct AgentPaneReplyImages {
    static let maximumBytes = 10 << 20
    /// Most pixels a decoded image may have (a 8K photo is 33 M).
    static let maximumPixels = 50_000_000
    /// Longest side of a re-encoded web image.
    static let maximumSide = 2048
    /// Longest side of a PDF's first-page thumbnail.
    static let thumbnailSide = 1024
    /// Largest PDF the host opens for a thumbnail (only its first page is drawn).
    static let maximumPDFBytes = 100 << 20

    /// Types the page draws as they are.
    static let nativeTypes: [String: String] = [
        UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif", UTType.webP.identifier: "image/webp",
    ]
    /// Other raster types the host decodes and re-encodes.
    static let decodedTypes: Set<String> = [UTType.heic.identifier, UTType.tiff.identifier, UTType.bmp.identifier]

    /// The image file at `path` (already checked to be inside a root) as a data URL.
    /// Reads and decodes off the main actor.
    @concurrent static func local(_ path: String) async -> Result<String, AgentPaneReplyError> {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true
        else { return .failure(.pathInvalid) }
        if url.pathExtension.lowercased() == "pdf" {
            guard (values.fileSize ?? Int.max) <= maximumPDFBytes else { return .failure(.imageTooLarge) }
            return pdfThumbnail(url)
        }
        guard (values.fileSize ?? Int.max) <= maximumBytes else { return .failure(.imageTooLarge) }
        // concurrency-allow: local(_:) is @concurrent, so this read never runs on the main actor
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= maximumBytes else {
            return .failure(.imageFailed)
        }
        if url.pathExtension.lowercased() == "svg" {
            guard let clean = AgentPaneSVGSanitizer.sanitize(data) else { return .failure(.imageFailed) }
            return .success("data:image/svg+xml;base64," + clean.base64EncodedString())
        }
        return raster(data, reencode: false)
    }

    /// The first page of the PDF at `url` on white, at most ``thumbnailSide`` on its longest side,
    /// as a PNG data URL. A file CoreGraphics cannot read as a PDF is refused.
    static func pdfThumbnail(_ url: URL) -> Result<String, AgentPaneReplyError> {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted || document.isUnlocked,
              let page = document.page(at: 1) else { return .failure(.imageFailed) }
        let crop = page.getBoxRect(.cropBox)
        var box = crop
        if page.rotationAngle % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return .failure(.imageFailed) }
        let scale = CGFloat(thumbnailSide) / max(box.width, box.height)
        let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return .failure(.imageFailed) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // By hand, since getDrawingTransform never scales a page up: centre the crop box, turn it
        // clockwise by the page's /Rotate, scale it to the canvas and draw only what it shows.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(page.rotationAngle) * .pi / 180)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.midX, y: -crop.midY)
        context.clip(to: crop)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return .failure(.imageFailed) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return .failure(.imageFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return .failure(.imageFailed) }
        return .success("data:image/png;base64," + (output as Data).base64EncodedString())
    }

    /// Bytes from a web fetch as a PNG data URL.
    @concurrent static func remote(_ data: Data) async -> Result<String, AgentPaneReplyError> {
        raster(data, reencode: true)
    }

    /// `data` as a raster data URL: kept as it is when the page draws its type and `reencode` is
    /// false, else decoded (at most ``maximumSide``) and written again as PNG.
    static func raster(_ data: Data, reencode: Bool) -> Result<String, AgentPaneReplyError> {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0,
              nativeTypes[type] != nil || decodedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= maximumPixels
        else { return .failure(.imageFailed) }
        if !reencode, let mime = nativeTypes[type] {
            // Decode once, so a file that is not really this type is refused.
            guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
            else { return .failure(.imageFailed) }
            return .success("data:\(mime);base64," + data.base64EncodedString())
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failure(.imageFailed) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return .failure(.imageFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return .failure(.imageFailed) }
        return .success("data:image/png;base64," + (output as Data).base64EncodedString())
    }
}

/// Rebuilds an SVG file without what could run or load anything: `script`, `foreignObject` and
/// embedded documents, every `on*` attribute, `style` attributes with `url(`, and any `href`
/// that is not a fragment (`#id`). No DTD or entity is read. The page draws the result only as
/// an `<img>`, where WebKit runs no script and loads nothing either; this is the second wall.
nonisolated final class AgentPaneSVGSanitizer: NSObject, XMLParserDelegate {
    private static let droppedElements: Set<String> = [
        "script", "foreignobject", "iframe", "object", "embed", "audio", "video", "handler", "listener", "set", "animate",
    ]

    private var output = ""
    private var skipping = 0
    /// Inside a `<style>` element: its text keeps no `@import` and no `url(` that is not `url(#`.
    private var inStyle = false
    private var sawRoot = false
    private var failed = false

    static func sanitize(_ data: Data) -> Data? {
        let delegate = AgentPaneSVGSanitizer()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot, !delegate.failed else { return nil }
        return Data(delegate.output.utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func keeps(_ name: String, _ value: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("on") { return false }
        if lower == "href" || lower.hasSuffix(":href") { return value.hasPrefix("#") }
        if lower == "style" || lower == "filter" || lower == "mask" || lower == "clip-path" || lower == "fill" || lower == "stroke" {
            let compact = value.lowercased().filter { !$0.isWhitespace }
            return !compact.contains("url(") || compact.contains("url(#")
        }
        return true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
        if !sawRoot {
            guard local == "svg" else {
                failed = true
                parser.abortParsing()
                return
            }
            sawRoot = true
        }
        if skipping > 0 || Self.droppedElements.contains(local) {
            skipping += 1
            return
        }
        output += "<" + elementName
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) where Self.keeps(name, value) {
            output += " \(name)=\"\(Self.escape(value))\""
        }
        output += ">"
        inStyle = local == "style"
        if output.utf8.count > AgentPaneReplyImages.maximumBytes { failed = true; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if skipping > 0 {
            skipping -= 1
            return
        }
        inStyle = false
        output += "</\(elementName)>"
    }

    private func styleText(_ text: String) -> String {
        guard inStyle else { return text }
        let compact = text.lowercased().filter { !$0.isWhitespace }
        let linksOut = compact.contains("@import") || compact.components(separatedBy: "url(").dropFirst().contains { !$0.hasPrefix("#") }
        return linksOut ? "" : text
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipping == 0 { output += Self.escape(styleText(string)) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if skipping == 0 { output += Self.escape(styleText(String(decoding: CDATABlock, as: UTF8.self))) }
    }
}

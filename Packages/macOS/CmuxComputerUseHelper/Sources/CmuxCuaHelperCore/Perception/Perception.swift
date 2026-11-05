// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import os

private let perceptionLogger = Logger(subsystem: "com.cmuxterm.cua", category: "perception")

/// What one helper connection (one agent session's `acpmux cua-mcp` bridge)
/// has been shown, per window: the baseline for "unchanged", the frame a
/// zoom region is measured in, and the last zoom this helper made.
public final class PerceptionSession: Sendable {
    struct Window: Sendable {
        var signature: ScreenSignature?
        var frame: ScreenshotFrame?
        var zoom: ZoomMapping?
    }

    private let windows = OSAllocatedUnfairLock<[UInt32: Window]>(initialState: [:])

    public init() {}

    func window(_ id: UInt32) -> Window { windows.withLock { $0[id] ?? Window() } }

    func update(_ id: UInt32, _ change: @Sendable (inout Window) -> Void) {
        windows.withLock { all in
            var window = all[id] ?? Window()
            change(&window)
            all[id] = window
        }
    }
}

/// Captures a zoom region again at native resolution; ScreenCaptureKit in
/// production, a fake in tests.
protocol ZoomCapturing: Sendable {
    func capture(windowID: UInt32, region: PerceptionZoom.Region, frame: ScreenshotFrame) async throws
        -> (CGImage, ZoomMapping)
}

extension PerceptionZoom: ZoomCapturing {}

/// Reads text from a screenshot; Vision in production, a fake in tests.
protocol TextRecognizing: Sendable {
    func lines(in image: CGImage) throws -> [OCRLine]
}

extension PerceptionOCR: TextRecognizing {}

/// The helper's view of the screen, between the agent and Cua Driver. The
/// driver still runs every call (target guard, consent, snapshots, element
/// tokens); this layer only rewrites what comes back, so the agent sees less
/// and sharper:
///
/// * `get_window_state` / `get_app_state`: a screenshot the agent already saw
///   of this window on this connection is answered "unchanged" with no image;
///   one that changed in a small area comes back as a crop of that area; any
///   other comes back as JPEG instead of PNG (the same pixels, so the same
///   tokens, a fraction of the bytes). `ocr: true` (or `capture_mode: "som"`)
///   adds Apple Vision word boxes in screenshot pixels, and the text of the
///   words inside each element's `screenshot_frame`. `force_screenshot: true`
///   always returns the full image; `perception: false` turns all of it off.
/// * `zoom`: after the driver's own zoom succeeds, the region is captured
///   again at the display's native resolution (up to 1568 px), instead of a
///   crop of the window capture scaled down to 500 px wide. A later
///   `from_zoom: true` action is translated here, from that image back to
///   screenshot pixels.
///
/// The accessibility tree's deltas are upstream's: `since: <snapshot_id>`
/// (cua-driver v0.38, `window_state_view`).
struct Perception: Sendable {
    let tools: any ToolInvoking
    let session: PerceptionSession
    var ocr: any TextRecognizing = PerceptionOCR()
    var zoomCapture: any ZoomCapturing = PerceptionZoom()

    /// A changed area at most this share of the screenshot comes back as a crop.
    static let cropMaxPercent = 35
    static let readTools: Set<String> = ["get_window_state", "get_app_state"]
    /// Pointer arguments a `from_zoom` action carries, as (x, y) pairs.
    static let pointKeys = [("x", "y"), ("from_x", "from_y"), ("to_x", "to_y")]

    func call(name: String, arguments: Data) async throws -> Data {
        guard var args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] else {
            return try await tools.invoke(name: name, arguments: arguments)
        }
        if let enabled = args.removeValue(forKey: "perception") as? Bool, !enabled {
            Self.stripOwnArguments(name: name, &args)
            return try await tools.invoke(name: name, arguments: HelperWire.json(args))
        }
        if Self.readTools.contains(name) { return try await read(name: name, args) }
        if name == "zoom" { return try await zoom(args) }
        guard let translated = translateFromZoom(args) else { return try await tools.invoke(name: name, arguments: arguments) }
        return try await tools.invoke(name: name, arguments: HelperWire.json(translated))
    }

    static func stripOwnArguments(name: String, _ args: inout [String: Any]) {
        guard readTools.contains(name) else { return }
        args.removeValue(forKey: "ocr")
        args.removeValue(forKey: "force_screenshot")
        if args["capture_mode"] as? String == "som" { args.removeValue(forKey: "capture_mode") }
    }

    // MARK: get_window_state

    private func read(name: String, _ arguments: [String: Any]) async throws -> Data {
        var args = arguments
        let wantsOCR = args["ocr"] as? Bool == true || args["capture_mode"] as? String == "som"
        let force = args["force_screenshot"] as? Bool == true
        Self.stripOwnArguments(name: name, &args)
        let started = ContinuousClock.now
        let result = try await tools.invoke(name: name, arguments: HelperWire.json(args))
        let driverTime = ContinuousClock.now - started
        guard var reply = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              reply["isError"] as? Bool != true,
              var content = reply["content"] as? [[String: Any]],
              let imageIndex = content.firstIndex(where: { $0["type"] as? String == "image" }),
              let encoded = content[imageIndex]["data"] as? String,
              let image = PerceptionImage.decode(base64: encoded) else { return result }
        var structured = reply["structuredContent"] as? [String: Any] ?? [:]
        let windowID = (structured["window_id"] as? NSNumber)?.uint32Value
        var stats: [String: Any] = ["driver_ms": Self.milliseconds(driverTime),
                                    "driver_image_bytes": encoded.utf8.count,
                                    "image_width": image.width, "image_height": image.height]
        let processing = ContinuousClock.now

        if let windowID {
            let bounds = structured["window_bounds"] as? [String: Any]
            let frame = ScreenshotFrame(width: image.width, height: image.height,
                                        windowWidth: (bounds?["width"] as? NSNumber)?.doubleValue ?? Double(image.width),
                                        windowHeight: (bounds?["height"] as? NSNumber)?.doubleValue ?? Double(image.height))
            session.update(windowID) { $0.frame = frame; $0.zoom = nil }
        }

        if wantsOCR {
            let ocrStarted = ContinuousClock.now
            do {
                let lines = try ocr.lines(in: image)
                content.append(["type": "text", "text": PerceptionOCR.render(lines)])
                structured["ocr_lines"] = lines.map(Self.json)
                if let elements = structured["elements"] as? [[String: Any]] {
                    structured["elements"] = Self.attach(lines.flatMap(\.words), to: elements)
                }
                stats["ocr_words"] = lines.reduce(0) { $0 + $1.words.count }
            } catch {
                content.append(["type": "text", "text": "OCR failed: \(error)"])
            }
            stats["ocr_ms"] = Self.milliseconds(ContinuousClock.now - ocrStarted)
        }

        let signature = ScreenSignature(image: image)
        let previous = windowID.flatMap { session.window($0).signature }
        let change = force ? nil : signature.flatMap { new in previous.flatMap { new.change(since: $0) } }
        var baseline = signature
        var imageBytes = 0
        if let change, change.rect == nil {
            content[imageIndex] = ["type": "text", "text":
                "Screenshot unchanged: it looks the same as this window's last screenshot in this session " +
                "(\(image.width)x\(image.height) px), so it is not sent again. Coordinates stay in that " +
                "screenshot's pixels. Pass force_screenshot: true to get the image anyway."]
            structured["screenshot_unchanged"] = true
            stats["screenshot"] = "unchanged"
            stats["image_tokens"] = 0
            baseline = previous
        } else if let rect = change?.rect, rect.area * 100 <= image.width * image.height * Self.cropMaxPercent,
                  let crop = PerceptionImage.crop(image, to: rect), let jpeg = PerceptionImage.jpeg(crop) {
            let data = jpeg.base64EncodedString()
            content[imageIndex] = ["type": "image", "mimeType": "image/jpeg", "data": data]
            content.insert(["type": "text", "text":
                "Only part of the screenshot changed since this window's last one in this session: the image " +
                "is the region x=\(rect.x) y=\(rect.y) \(rect.width)x\(rect.height) of the " +
                "\(image.width)x\(image.height) screenshot; the rest looks the same. Coordinates stay in " +
                "full-screenshot pixels: add \(rect.x),\(rect.y) to a point in this image. Pass " +
                "force_screenshot: true for the whole image."], at: imageIndex)
            structured["screenshot_dirty_rect"] = rect.json
            structured["screenshot_mime_type"] = "image/jpeg"
            stats["screenshot"] = "dirty_rect"
            stats["image_tokens"] = PerceptionImage.estimatedTokens(width: rect.width, height: rect.height)
            imageBytes = data.utf8.count
        } else {
            if let jpeg = PerceptionImage.jpeg(image) {
                let data = jpeg.base64EncodedString()
                if data.utf8.count < encoded.utf8.count {
                    content[imageIndex] = ["type": "image", "mimeType": "image/jpeg", "data": data]
                    structured["screenshot_mime_type"] = "image/jpeg"
                }
            }
            stats["screenshot"] = "full"
            stats["image_tokens"] = PerceptionImage.estimatedTokens(width: image.width, height: image.height)
            imageBytes = (content[imageIndex]["data"] as? String)?.utf8.count ?? encoded.utf8.count
        }
        if let windowID, let baseline { session.update(windowID) { $0.signature = baseline } }
        stats["image_bytes"] = imageBytes
        stats["perception_ms"] = Self.milliseconds(ContinuousClock.now - processing)
        structured["perception"] = stats
        reply["content"] = content
        reply["structuredContent"] = structured
        perceptionLogger.info("\(name, privacy: .public) screenshot=\(stats["screenshot"] as? String ?? "", privacy: .public) driver_bytes=\(encoded.utf8.count) bytes=\(imageBytes)")
        return HelperWire.json(reply)
    }

    /// Each element with a `screenshot_frame` gets the words whose centre is inside it.
    static func attach(_ words: [OCRWord], to elements: [[String: Any]]) -> [[String: Any]] {
        elements.map { element in
            guard let frame = element["screenshot_frame"] as? [String: Any],
                  let x = (frame["x"] as? NSNumber)?.intValue, let y = (frame["y"] as? NSNumber)?.intValue,
                  let w = (frame["w"] as? NSNumber)?.intValue, let h = (frame["h"] as? NSNumber)?.intValue else {
                return element
            }
            let inside = words.filter { word in
                let cx = word.rect.x + word.rect.width / 2, cy = word.rect.y + word.rect.height / 2
                return cx >= x && cx < x + w && cy >= y && cy < y + h
            }
            guard !inside.isEmpty else { return element }
            var tagged = element
            tagged["ocr_text"] = inside.map(\.text).joined(separator: " ")
            return tagged
        }
    }

    static func json(_ line: OCRLine) -> [String: Any] {
        ["text": line.text, "rect": line.rect.json,
         "words": line.words.map { ["text": $0.text, "rect": $0.rect.json, "confidence": Double($0.confidence)] }]
    }

    // MARK: zoom

    private func zoom(_ args: [String: Any]) async throws -> Data {
        let result = try await tools.invoke(name: "zoom", arguments: HelperWire.json(args))
        guard let windowID = (args["window_id"] as? NSNumber)?.uint32Value,
              let frame = session.window(windowID).frame,
              let region = PerceptionZoom.region(args, frame: frame),
              var reply = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              reply["isError"] as? Bool != true,
              var content = reply["content"] as? [[String: Any]],
              let imageIndex = content.firstIndex(where: { $0["type"] as? String == "image" }) else { return result }
        let image: CGImage
        let mapping: ZoomMapping
        do {
            (image, mapping) = try await zoomCapture.capture(windowID: windowID, region: region, frame: frame)
        } catch {
            perceptionLogger.notice("zoom: native capture failed, keeping the driver's crop: \(String(describing: error), privacy: .public)")
            return result
        }
        guard let jpeg = PerceptionImage.jpeg(image) else { return result }
        let r = region.pixels
        content[imageIndex] = ["type": "image", "mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]
        content.removeAll { $0["type"] as? String == "text" }
        content.append(["type": "text", "text": String(
            format: "Zoom of screenshot region (%.0f,%.0f)-(%.0f,%.0f) with 20%% padding, captured again at native " +
                "resolution: %dx%d px JPEG. A point (u,v) in this image is (%.0f + u*%.3f, %.0f + v*%.3f) in " +
                "screenshot pixels; or pass from_zoom: true with the point in this image.",
            r.minX, r.minY, r.maxX, r.maxY, image.width, image.height,
            mapping.originX, mapping.pixelsPerZoomPixel, mapping.originY, mapping.pixelsPerZoomPixel)])
        var structured = reply["structuredContent"] as? [String: Any] ?? [:]
        structured["width"] = image.width
        structured["height"] = image.height
        structured["format"] = "jpeg"
        structured["mime_type"] = "image/jpeg"
        structured["native_resolution"] = true
        structured["zoom_origin"] = ["x": mapping.originX, "y": mapping.originY]
        structured["zoom_screenshot_pixels_per_pixel"] = mapping.pixelsPerZoomPixel
        reply["content"] = content
        reply["structuredContent"] = structured
        session.update(windowID) { $0.zoom = mapping }
        return HelperWire.json(reply)
    }

    /// A `from_zoom` action after this helper's own zoom: its points are in
    /// that image, which the driver's zoom context does not know, so they are
    /// translated to screenshot pixels here and `from_zoom` is dropped.
    /// nil when the call is not such an action (it goes to the driver as sent).
    func translateFromZoom(_ arguments: [String: Any]) -> [String: Any]? {
        guard arguments["from_zoom"] as? Bool == true,
              let windowID = (arguments["window_id"] as? NSNumber)?.uint32Value,
              let mapping = session.window(windowID).zoom else { return nil }
        var args = arguments
        for (xKey, yKey) in Self.pointKeys {
            guard let x = (args[xKey] as? NSNumber)?.doubleValue, let y = (args[yKey] as? NSNumber)?.doubleValue else {
                continue
            }
            let point = mapping.screenshotPoint(x: x, y: y)
            args[xKey] = point.x.rounded()
            args[yKey] = point.y.rounded()
        }
        args.removeValue(forKey: "from_zoom")
        return args
    }

    // MARK: tools/list

    /// The driver's tool list with this layer's arguments and zoom's real output size.
    static func listing(_ data: Data) -> Data {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard let tools = (parsed as? [String: Any])?["tools"] as? [[String: Any]] ?? parsed as? [[String: Any]] else {
            return data
        }
        let patched = tools.map { tool -> [String: Any] in
            var tool = tool
            let name = tool["name"] as? String ?? ""
            let schemaKey = tool["inputSchema"] != nil ? "inputSchema" : "input_schema"
            if readTools.contains(name), var schema = tool[schemaKey] as? [String: Any] {
                var properties = schema["properties"] as? [String: Any] ?? [:]
                properties["ocr"] = ["type": "boolean", "description":
                    "Add Apple Vision OCR (on device) of the screenshot: each text line and word with its box in " +
                    "screenshot pixels, and `ocr_text` on each element whose screenshot_frame holds words. " +
                    "capture_mode \"som\" does the same."]
                properties["force_screenshot"] = ["type": "boolean", "description":
                    "Return the whole screenshot even when it looks the same as this window's last one in this " +
                    "session (by default an unchanged screenshot is not sent again, and a small change comes " +
                    "back as a crop of the changed region)."]
                properties["perception"] = ["type": "boolean", "description":
                    "false: the driver's reply as is (no unchanged check, crop, JPEG or OCR)."]
                if var mode = properties["capture_mode"] as? [String: Any], var values = mode["enum"] as? [String],
                   !values.contains("som") {
                    values.append("som")
                    mode["enum"] = values
                    properties["capture_mode"] = mode
                }
                schema["properties"] = properties
                tool[schemaKey] = schema
            }
            if name == "zoom", let description = tool["description"] as? String {
                tool["description"] = description.replacingOccurrences(
                    of: "The output image is at most 500 px wide.",
                    with: "The region is captured again at native resolution (at most 1568 px on its long edge).")
            }
            return tool
        }
        guard var root = parsed as? [String: Any] else { return HelperWire.json(patched) }
        root["tools"] = patched
        return HelperWire.json(root)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) * 1000 + Double(attoseconds) / 1e15).rounded()
    }
}

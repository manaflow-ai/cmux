// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

/// The perception eval: a fixed task set of window reads replayed through
/// `Perception`, before (the driver's reply as is) and after. Each step is a
/// rendered code editor window (13 pt Menlo, Retina, delivered at the
/// driver's default 1366 px long edge), so the numbers repeat on any Mac.
/// Prints one table row per step and, with CMUX_PERCEPTION_BENCH_OUT set,
/// writes the rows there as JSON (schema cmux.perception-bench/1).
@Suite struct PerceptionBenchTests {
    static let width = 1366, height = 880
    /// A 1440 pt wide window on a 2x display, delivered at 1366 px: 0.95 px per point.
    static let pixelsPerPoint = 1366.0 / 1440.0
    static let lineHeight = 17 * pixelsPerPoint
    static let code = (0..<120).map { "    let value\($0) = compute(\"row \($0)\", scale: \($0 % 7)) // step \($0)" }

    /// The editor window: `top` is the first visible source line; `typed` is
    /// appended to line 10; `menu` draws an open menu.
    static func editor(top: Int = 0, typed: String = "", menu: Bool = false, scale: Double = 1,
                       crop: CGRect? = nil) -> CGImage {
        let area = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
        let w = Int(area.width * scale), h = Int(area.height * scale)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -(CGFloat(height) - area.maxY))
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 13 * pixelsPerPoint, nil)
        for row in 0..<Int(Double(height - 40) / lineHeight) {
            let index = top + row
            guard index < code.count else { break }
            let text = code[index] + (index == 10 ? typed : "")
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 16, y: CGFloat(height) - 40 - CGFloat(row + 1) * lineHeight + 5)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) - 32, width: CGFloat(width), height: 32))
        if menu {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 40, y: CGFloat(height) - 32 - 300, width: 240, height: 300))
            context.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
            context.stroke(CGRect(x: 40, y: CGFloat(height) - 32 - 300, width: 240, height: 300))
        }
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> String {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return (data as Data).base64EncodedString()
    }

    static func characterErrorRate(_ read: String, truth: String) -> Double {
        let a = Array(read), b = Array(truth)
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(a.isEmpty ? b.count : previous[b.count]) / Double(b.count)
    }

    struct Row: Codable {
        let step: String
        let beforeBytes: Int
        let afterBytes: Int
        let beforeTokens: Int
        let afterTokens: Int
        let perceptionMs: Double
        let screenshot: String
    }

    @Test func fixedTaskSet() async throws {
        let steps: [(String, CGImage)] = [
            ("open", Self.editor()),
            ("re-read, nothing changed", Self.editor()),
            ("type a word", Self.editor(typed: " + x")),
            ("re-read after typing", Self.editor(typed: " + x")),
            ("open a menu", Self.editor(typed: " + x", menu: true)),
            ("close it", Self.editor(typed: " + x")),
            ("scroll 5 lines", Self.editor(top: 5, typed: " + x")),
            ("re-read after scroll", Self.editor(top: 5, typed: " + x")),
        ]
        let tools = PerceptionTests.ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        var rows: [Row] = []
        for (name, image) in steps {
            let png = Self.png(image)
            tools.queue(PerceptionTests.windowState(png))
            let reply = try PerceptionTests.reply(try await perception.call(name: "get_window_state",
                                                                            arguments: PerceptionTests.read))
            let stats = try #require(reply.structured["perception"] as? [String: Any])
            rows.append(Row(step: name, beforeBytes: png.utf8.count,
                            afterBytes: stats["image_bytes"] as? Int ?? 0,
                            beforeTokens: PerceptionImage.estimatedTokens(width: image.width, height: image.height),
                            afterTokens: stats["image_tokens"] as? Int ?? 0,
                            perceptionMs: stats["perception_ms"] as? Double ?? 0,
                            screenshot: stats["screenshot"] as? String ?? ""))
        }
        let total = (rows.reduce(0) { $0 + $1.beforeBytes }, rows.reduce(0) { $0 + $1.afterBytes },
                     rows.reduce(0) { $0 + $1.beforeTokens }, rows.reduce(0) { $0 + $1.afterTokens })
        var table = "perception-bench | step | bytes before | bytes after | image tokens before | after | ms added | screenshot\n"
        for row in rows {
            table += "perception-bench | \(row.step) | \(row.beforeBytes) | \(row.afterBytes) | \(row.beforeTokens) | " +
                "\(row.afterTokens) | \(row.perceptionMs) | \(row.screenshot)\n"
        }
        table += "perception-bench | total \(rows.count) steps | \(total.0) | \(total.1) | \(total.2) | \(total.3) | | \n"
        print(table)
        #expect(rows[1].screenshot == "unchanged" && rows[3].screenshot == "unchanged" && rows[7].screenshot == "unchanged")
        #expect(rows[2].screenshot == "dirty_rect", "one typed line is a crop")
        #expect(total.1 * 2 < total.0, "under half the bytes over the task set")
        #expect(total.3 * 2 < total.2, "under half the image tokens over the task set")
        if let out = ProcessInfo.processInfo.environment["CMUX_PERCEPTION_BENCH_OUT"] {
            let json = try JSONSerialization.data(withJSONObject: [
                "schema": "cmux.perception-bench/1",
                "rows": try rows.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
            ], options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: out))
        }
    }

    /// Zoom sharpness: OCR of a 13 pt line from upstream's zoom (a crop of
    /// the delivered screenshot, at most 500 px wide) against this helper's
    /// (the region drawn again at the display's 2x).
    @Test func zoomReadsSmallTextBetterAtNativeResolution() throws {
        let truth = Self.code[10]
        // Line 10's band, with upstream's 20% padding, in delivered pixels.
        let band = CGRect(x: 0, y: 40 + 10 * Self.lineHeight - 4, width: 640, height: Self.lineHeight + 8)
        let delivered = Self.editor()
        let crop = try #require(delivered.cropping(to: band))
        // Upstream: the crop scaled down to 500 px wide.
        let small = CGContext(data: nil, width: 500, height: Int(band.height * 500 / band.width), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let upstream = try #require(small.makeImage())
        // Native: the display's 2 px per point, over the delivered 0.95.
        let native = Self.editor(scale: 2 / Self.pixelsPerPoint, crop: band)
        let ocr = PerceptionOCR()
        let upstreamText = try ocr.lines(in: upstream).map(\.text).joined(separator: " ")
        let nativeText = try ocr.lines(in: native).map(\.text).joined(separator: " ")
        let upstreamCER = Self.characterErrorRate(upstreamText, truth: truth.trimmingCharacters(in: .whitespaces))
        let nativeCER = Self.characterErrorRate(nativeText, truth: truth.trimmingCharacters(in: .whitespaces))
        print("perception-bench | zoom OCR CER | upstream \(upstream.width)x\(upstream.height) \(upstreamCER) " +
              "| native \(native.width)x\(native.height) \(nativeCER) | upstream read: \(upstreamText) | native read: \(nativeText)")
        #expect(nativeCER <= upstreamCER)
    }

    /// OCR in som mode: how well Vision reads the delivered screenshot, and what it costs.
    @Test func ocrOfTheDeliveredScreenshot() throws {
        let image = Self.editor()
        let started = ContinuousClock.now
        let lines = try PerceptionOCR().lines(in: image)
        let ms = Perception.milliseconds(ContinuousClock.now - started)
        let visible = Self.code.prefix(Int(Double(Self.height - 40) / Self.lineHeight))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let read = lines.map(\.text)
        let matched = visible.filter { line in read.contains { Self.characterErrorRate($0, truth: line) < 0.05 } }.count
        let words = lines.reduce(0) { $0 + $1.words.count }
        let text = PerceptionOCR.render(lines)
        print("perception-bench | som OCR | \(lines.count) lines, \(words) words, \(matched)/\(visible.count) lines " +
              "under 5% CER | \(ms) ms | \(text.utf8.count) bytes of OCR text")
        #expect(matched * 10 >= visible.count * 9)
    }
}

// alignscan: leading-edge measurements of a simulator screenshot, for measure.py.
//
//   alignscan IMAGE SCALE [BANDS_JSON]
//
// Prints one JSON object (points, top-left origin):
//   ocr:        every Vision text line: text, box (x y w h), ink_x (where the line's own ink
//               starts: the first ink cluster that overlaps the box, so a dot, chevron or icon
//               left of the text is not counted), first_char_x (Vision's box of the first
//               character), confidence
//   separators: thin horizontal lines (1 to 2 px tall, at least 100 pt long, a different color
//               from the rows right above and below): y, x0, x1
//   bands:      for each [y0, y1, xmax] of BANDS_JSON, the ink clusters [x0, x1] in that band
//               left of xmax (gutter marks: status dots, chevrons, icons)
// Background of a band is its most common color; ink is a pixel whose largest channel
// difference from that background is more than 38 (of 255).
import AppKit
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3, let img = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: alignscan IMAGE SCALE [BANDS_JSON]\n".data(using: .utf8)!)
    exit(2)
}
let W = cg.width, H = cg.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

@inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * W + x) * 4
    return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
}
@inline(__always) func diff(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}
func background(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> (Int, Int, Int) {
    var counts: [Int: Int] = [:]
    var y = max(0, y0)
    while y < min(H, y1) {
        var x = max(0, x0)
        while x < min(W, x1) {
            let c = rgb(x, y)
            counts[(c.0 >> 2) << 12 | (c.1 >> 2) << 6 | (c.2 >> 2), default: 0] += 1
            x += 2
        }
        y += 2
    }
    let k = counts.max { $0.value < $1.value }?.key ?? 0
    return (((k >> 12) & 63) << 2, ((k >> 6) & 63) << 2, (k & 63) << 2)
}
let inkThreshold = 38
/// Ink clusters [x0, x1) in device pixels between rows y0..<y1 and columns x0..<x1, joined
/// across gaps shorter than `gap` px.
func clusters(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int, gap: Int) -> [(Int, Int)] {
    let ya = max(0, y0), yb = min(H, y1), xa = max(0, x0), xb = min(W, x1)
    guard yb > ya, xb > xa else { return [] }
    let bg = background(ya, yb, 0, W)
    var cols = [Bool](repeating: false, count: xb - xa)
    for x in xa..<xb {
        for y in ya..<yb where diff(rgb(x, y), bg) > inkThreshold { cols[x - xa] = true; break }
    }
    var out: [(Int, Int)] = []
    var start: Int? = nil, lastInk = -1000
    for i in 0..<cols.count {
        guard cols[i] else { continue }
        let x = xa + i
        if let s = start, x - lastInk > gap { out.append((s, lastInk + 1)); start = x }
        if start == nil { start = x }
        lastInk = x
    }
    if let s = start { out.append((s, lastInk + 1)) }
    return out
}

func pt(_ v: Int) -> Double { (Double(v) / scale * 10).rounded() / 10 }
func ptd(_ v: Double) -> Double { (v * 10).rounded() / 10 }

// ---- OCR -------------------------------------------------------------------
// Vision's accurate model sometimes fails to load on a busy host (e5rt error): retry, then .fast.
var req = VNRecognizeTextRequest()
var recognized = false
for level in [VNRequestTextRecognitionLevel.accurate, .accurate, .accurate, .fast] where !recognized {
    req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: cg).perform([req]); recognized = true }
    catch { FileHandle.standardError.write("ocr retry: \(error)\n".data(using: .utf8)!); Thread.sleep(forTimeInterval: 1) }
}
let Wpt = Double(W) / scale, Hpt = Double(H) / scale
var ocr: [[String: Any]] = []
for o in req.results ?? [] {
    guard let t = o.topCandidates(1).first else { continue }
    let b = o.boundingBox
    let bx = b.minX * Wpt, by = (1 - b.maxY) * Hpt, bw = b.width * Wpt, bh = b.height * Hpt
    var item: [String: Any] = ["text": t.string, "x": ptd(bx), "y": ptd(by), "w": ptd(bw), "h": ptd(bh),
                               "confidence": ptd(Double(t.confidence))]
    if let r = t.string.indices.first.map({ $0..<t.string.index(after: $0) }),
       let fb = try? t.boundingBox(for: r)?.boundingBox {
        item["first_char_x"] = ptd(fb.minX * Wpt)
    }
    // The line's own ink: rows in the middle 70% of the box (neighbour lines stay out),
    // columns from 12 pt left of the box; clusters joined across gaps < 2.5 pt (letter and
    // word gaps are narrower than the gap between a mark and the text).
    let y0 = Int((by + bh * 0.15) * scale), y1 = Int((by + bh * 0.85) * scale)
    let x0 = Int(max(0, bx - 12) * scale), x1 = Int((bx + bw) * scale)
    let cs = clusters(y0, y1, x0, x1, gap: Int(2.5 * scale))
    if let own = cs.first(where: { Double($0.1) / scale > bx + 2 }) {
        item["ink_x"] = pt(own.0)
        item["ink_x1"] = pt(cs.last!.1)
    }
    ocr.append(item)
}

// ---- separators --------------------------------------------------------------
var seps: [[String: Any]] = []
var lastY = -10
for y in 3..<(H - 3) {
    var x = 0
    var best: (Int, Int)? = nil
    while x < W {
        let c = rgb(x, y)
        guard diff(c, rgb(x, y - 2)) > 5, diff(c, rgb(x, y + 2)) > 5 else { x += 1; continue }
        var e = x
        while e + 1 < W {
            let n = rgb(e + 1, y)
            if diff(n, c) > 10 || diff(n, rgb(e + 1, y - 2)) <= 5 || diff(n, rgb(e + 1, y + 2)) <= 5 { break }
            e += 1
        }
        if e - x + 1 >= Int(100 * scale), best == nil || (e - x) > (best!.1 - best!.0) { best = (x, e + 1) }
        x = e + 1
    }
    if let b = best {
        if y - lastY > 1 { seps.append(["y": pt(y), "x0": pt(b.0), "x1": pt(b.1)]) }
        lastY = y
    }
}

// ---- bands ---------------------------------------------------------------------
var bands: [[[Double]]] = []
if args.count >= 4, let data = args[3].data(using: .utf8),
   let list = try? JSONSerialization.jsonObject(with: data) as? [[Double]] {
    for band in list where band.count >= 3 {
        let cs = clusters(Int(band[0] * scale), Int(band[1] * scale), 0, Int(band[2] * scale), gap: Int(1.5 * scale))
        bands.append(cs.map { [pt($0.0), pt($0.1)] })
    }
}

let out: [String: Any] = ["w": ptd(Wpt), "h": ptd(Hpt), "scale": scale, "ocr": ocr, "separators": seps, "bands": bands]
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)

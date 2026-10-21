import Foundation
import Vision
import AppKit
// usage: ocr IMAGE  -> one line per text: x y w h<TAB>text  (points, top-left origin, 3x screenshot)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cg).perform([req])
let W = Double(cg.width) / 3, H = Double(cg.height) / 3
for o in req.results ?? [] {
    guard let t = o.topCandidates(1).first else { continue }
    let b = o.boundingBox
    print(String(format: "%.0f %.0f %.0f %.0f\t%@", b.minX * W, (1 - b.maxY) * H, b.width * W, b.height * H, t.string))
}

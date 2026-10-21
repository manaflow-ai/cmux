import Foundation
import Vision
import AppKit
// usage: ocr-batch [--fast] [--scale S] [--jobs N] IMAGE...   (or file paths on stdin when no IMAGE is given)
// For each image, in input order: a line "== PATH", then one line per text: x y w h<TAB>text
// in image px divided by S (default 1; pass 3 for points of a 3x screenshot), top-left origin.
// --jobs: images recognized at once (default 1; Vision accurate contends badly above ~2).
var args = Array(CommandLine.arguments.dropFirst())
var fast = false
var scale = 1.0
var jobs = 1
var files: [String] = []
var i = 0
while i < args.count {
    switch args[i] {
    case "--fast": fast = true
    case "--scale": i += 1; scale = Double(args[i]) ?? 1
    case "--jobs": i += 1; jobs = max(1, Int(args[i]) ?? 1)
    default: files.append(args[i])
    }
    i += 1
}
if files.isEmpty {
    while let line = readLine() { if !line.isEmpty { files.append(line) } }
}
var out = [String](repeating: "", count: files.count)
let lock = NSLock()
func recognize(_ n: Int) {
    var s = "== \(files[n])\n"
    let url = URL(fileURLWithPath: files[n])
    if let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        if #available(macOS 13.0, *) { req.automaticallyDetectsLanguage = false }
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let W = Double(cg.width) / scale, H = Double(cg.height) / scale
        for o in req.results ?? [] {
            guard let t = o.topCandidates(1).first else { continue }
            let b = o.boundingBox
            s += String(format: "%.1f %.1f %.1f %.1f\t%@\n", b.minX * W, (1 - b.maxY) * H, b.width * W, b.height * H, t.string)
        }
    }
    lock.lock(); out[n] = s; lock.unlock()
}
DispatchQueue.concurrentPerform(iterations: jobs) { j in
    var n = j
    while n < files.count { recognize(n); n += jobs }
}
for s in out { FileHandle.standardOutput.write(s.data(using: .utf8)!) }

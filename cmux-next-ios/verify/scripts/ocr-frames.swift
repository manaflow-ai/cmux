// Prints each frame's recognized text on one line: "<file>\t<text>".
// usage: swift verify/scripts/ocr-frames.swift <frame.png>...
import AppKit
import Vision

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: cg).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
    print("\((path as NSString).lastPathComponent)\t\(text)")
}

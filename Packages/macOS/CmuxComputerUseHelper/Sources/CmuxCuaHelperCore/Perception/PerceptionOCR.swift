// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Vision

/// One recognised word, in pixels of the screenshot it was read from.
struct OCRWord: Equatable, Sendable {
    let text: String
    let rect: PixelRect
    let confidence: Float
}

/// One recognised line and its words.
struct OCRLine: Equatable, Sendable {
    let text: String
    let rect: PixelRect
    let words: [OCRWord]
}

/// Apple Vision text recognition, on device (`VNRecognizeTextRequest`). No
/// model leaves the Mac and nothing is downloaded: the recogniser ships with
/// macOS.
struct PerceptionOCR: Sendable {
    /// Vision's accurate recogniser; the fast one misreads small UI text.
    var accurate = true

    func lines(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // UI labels, paths and code are not prose: language correction
        // rewrites them ("cmux" -> "crux").
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = Double(image.width), height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let line = Self.pixels(observation.boundingBox, width: width, height: height)
            let words = Self.wordRanges(candidate.string).compactMap { range -> OCRWord? in
                guard let box = try? candidate.boundingBox(for: range) else { return nil }
                return OCRWord(text: String(candidate.string[range]),
                               rect: Self.pixels(box.boundingBox, width: width, height: height),
                               confidence: candidate.confidence)
            }
            return OCRLine(text: candidate.string, rect: line, words: words)
        }
    }

    /// The whitespace-separated words of `text`.
    static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begun = start { ranges.append(begun..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begun = start { ranges.append(begun..<text.endIndex) }
        return ranges
    }

    /// Vision's normalised, bottom-left rectangle in top-left pixels.
    static func pixels(_ box: CGRect, width: Double, height: Double) -> PixelRect {
        let x = (box.minX * width).rounded(), y = ((1 - box.maxY) * height).rounded()
        return PixelRect(x: Int(x), y: Int(y),
                         width: Int((box.width * width).rounded()), height: Int((box.height * height).rounded()))
    }

    /// The model-facing text: one row per line, `x,y wxh: text`, then each
    /// word's left edge and width, so a word can be clicked at its centre.
    static func render(_ lines: [OCRLine]) -> String {
        var out = "OCR text (screenshot pixels; x,y wxh: line | word@x+w):\n"
        for line in lines {
            let r = line.rect
            out += "\(r.x),\(r.y) \(r.width)x\(r.height): \(line.text)"
            if line.words.count > 1 {
                out += " |" + line.words.map { " \($0.text)@\($0.rect.x)+\($0.rect.width)" }.joined()
            }
            out += "\n"
        }
        return out
    }
}

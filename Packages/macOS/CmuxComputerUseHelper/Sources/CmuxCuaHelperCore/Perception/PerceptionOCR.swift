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
    /// A screenshot with a long edge under this is also read at twice its
    /// size, and the read with more confident text wins. Which one reads 12 px
    /// UI text depends on the macOS release: on a 1366 px code window, macOS
    /// 27's Vision read 0% of the words as is and 79% at 2x, macOS 26's 58% as
    /// is and 15% at 2x (PerceptionBenchTests).
    var upscaleBelow = 2000

    func lines(in image: CGImage) throws -> [OCRLine] {
        let direct = try read(image, source: image)
        guard max(image.width, image.height) < upscaleBelow, let doubled = Self.scaled(image, by: 2) else { return direct }
        let upscaled = try read(image, source: doubled)
        return Self.score(upscaled) > Self.score(direct) ? upscaled : direct
    }

    /// Characters read, weighted by Vision's confidence.
    static func score(_ lines: [OCRLine]) -> Double {
        lines.reduce(0) { total, line in
            total + line.words.reduce(0) { $0 + Double($1.text.count) * Double($1.confidence) }
        }
    }

    /// Reads `source` (`image`, maybe scaled); boxes come back normalised, so they map onto `image`.
    private func read(_ image: CGImage, source: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // UI labels, paths and code are not prose: language correction
        // rewrites them ("cmux" -> "crux").
        request.usesLanguageCorrection = false
        // Vision's default skips text under about 1/32 of the image's height:
        // every 12 px label of a full window. Read down to 7 px.
        request.minimumTextHeight = Float(min(1, 7 / Double(max(1, image.height))))
        try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
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

    static func scaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

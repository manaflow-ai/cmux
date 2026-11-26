import CmuxMobileDesign
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// The phone's fork glyph is the icon pack's `agent.fork` (design/icons/source/agent-composer.json),
/// the split arrow the Mac and the web draw for Fork Conversation (Leo 2026-11-22: "let's just do
/// claude and codex's symbol for branching/forking chats"). The custom SF Symbol
/// (CmuxMobileDesign `cmux.fork.symbolset`) is that path's segments, each drawn as a round-capped
/// stroke outline in the SF Symbols template's units; this keeps the two in step, and keeps every
/// fork row on it.
@Suite struct ForkSymbolTests {
    /// The template's geometry: a 24-point grid at 4 units a point, its center on the middle of the
    /// small scale's cap height (baseline 0, cap line -70.459), and each weight's stroke radius.
    static let scale = 4.0
    static let capMiddle = -35.2295
    static let radii = [("Ultralight-S", 1.15), ("Regular-S", 3.7), ("Black-S", 6.2)]

    static func root() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("design/icons/source").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no design/icons/source above \(#filePath)")
            root = parent
        }
        return root
    }

    /// The split arrow's path (the sibling change to the pack's `agent.fork`, branch icons-split-arrow-fork).
    static let splitArrow = "M3.5 12h8l9-9M15.5 3h5v5M14.5 15l6 6M20.5 16v5h-5"

    /// The pack's `agent.fork` line drawing's path, or nil while the pack still has the drawing
    /// before the split arrow (nodes and a curve, before the sibling change lands).
    static func packPath(_ root: URL) throws -> String? {
        let data = try Data(contentsOf: root.appendingPathComponent("design/icons/source/agent-composer.json"))
        let pack = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let icons = try #require(pack["icons"] as? [[String: Any]])
        let fork = try #require(icons.first { $0["name"] as? String == "agent.fork" })
        let line = try #require(fork["line"] as? String)
        let paths = line.matches(of: /<path d='([^']+)'/).map { String($0.output.1) }
        guard paths.count == 1, !line.contains("<circle"), !line.contains("<rect") else { return nil }
        return paths[0]
    }

    /// Once the pack draws a single path for agent.fork, the symbol follows it.
    @Test func thePacksForkIsTheSplitArrow() throws {
        let root = try Self.root()
        guard let path = try Self.packPath(root) else { return }
        #expect(path == Self.splitArrow, "agent.fork changed: regenerate cmux.fork.svg from \(path) and update splitArrow")
    }

    /// Straight segments of a path of M, L, H and V commands (absolute or relative).
    static func segments(_ d: String) throws -> [(SIMD2<Double>, SIMD2<Double>)] {
        let tokens = d.matches(of: /[A-Za-z]|-?\d*\.?\d+/).map { String($0.output) }
        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        var at = SIMD2<Double>(0, 0)
        var command = ""
        var i = 0
        func number() throws -> Double {
            try #require(i < tokens.count, "\(d) ends inside \(command)")
            defer { i += 1 }
            return try #require(Double(tokens[i]), "\(tokens[i]) in \(d)")
        }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true {
                command = tokens[i]
                try #require("MmLlHhVv".contains(command), "agent.fork uses \(command); the symbol draws straight segments only")
                i += 1
                continue
            }
            let from = at
            let first = try number()
            switch command {
            case "M", "m", "L", "l":
                let second = try number()
                at = command == "M" || command == "L" ? SIMD2(first, second) : at + SIMD2(first, second)
            case "H": at.x = first
            case "h": at.x += first
            case "V": at.y = first
            default: at.y += first
            }
            // A move draws nothing; the numbers after it are lines.
            if command == "M" || command == "m" {
                command = command == "M" ? "L" : "l"
                continue
            }
            segments.append((from, at))
        }
        return segments
    }

    /// One segment's round-capped outline: along one side, a half circle round the end, back
    /// along the other side, a half circle round the start (quarter circles as cubic Béziers).
    static func capsule(_ a: SIMD2<Double>, _ b: SIMD2<Double>, radius r: Double) -> [Double] {
        func place(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * scale, (p.y - 12) * scale + capMiddle) }
        let (pa, pb) = (place(a), place(b))
        let delta = pb - pa
        let u = delta / (delta.x * delta.x + delta.y * delta.y).squareRoot()
        let n = SIMD2(-u.y, u.x)
        let k = 0.5522847498 * r
        func p(_ c: SIMD2<Double>, _ along: Double, _ across: Double) -> [Double] {
            let q = c + u * along + n * across
            return [q.x, q.y]
        }
        return p(pa, 0, r) + p(pb, 0, r)
            + p(pb, k, r) + p(pb, r, k) + p(pb, r, 0)
            + p(pb, r, -k) + p(pb, k, -r) + p(pb, 0, -r)
            + p(pa, 0, -r)
            + p(pa, -k, -r) + p(pa, -r, -k) + p(pa, -r, 0)
            + p(pa, -r, k) + p(pa, -k, r) + p(pa, 0, r)
    }

    static func format(_ numbers: [Double]) -> String {
        let s = numbers.map { String(format: "%.3f", $0) }
        let commands = ["M", " ", "L", " ", "C", " ", " ", " ", " ", " ", "C", " ", " ", " ", " ", " ", "L", " ",
                        "C", " ", " ", " ", " ", " ", "C", " ", " ", " ", " ", " "]
        return stride(from: 0, to: s.count, by: 30).map { start in
            (0..<30).map { commands[$0] + s[start + $0] }.joined() + "Z"
        }.joined()
    }

    @Test func theSymbolDrawsTheSplitArrow() throws {
        let root = try Self.root()
        let segments = try Self.segments(Self.splitArrow)
        #expect(segments.count == 7)
        let svgURL = root.appendingPathComponent(
            "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/Resources/Assets.xcassets/cmux.fork.symbolset/cmux.fork.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)
        for (weight, radius) in Self.radii {
            let expected = segments.flatMap { Self.capsule($0.0, $0.1, radius: radius) }
            let groupPattern = try Regex(#"<g id="\#(weight)"[^>]*>\s*<path d="([^"]+)""#)
            let group = try #require(svg.firstMatch(of: groupPattern),
                                     "no \(weight) in \(svgURL.lastPathComponent)")
            let d = try #require(group.output[1].substring)
            let drawn = d.matches(of: /-?\d*\.?\d+/).compactMap { Double($0.output) }
            let same = drawn.count == expected.count && zip(drawn, expected).allSatisfy { abs($0 - $1) < 0.002 }
            #expect(same, "\(weight) is not the split arrow; its path should be \(Self.format(expected))")
        }
    }

    /// Every fork row names the custom symbol, never the system's branch symbol (which Continue in… keeps).
    @Test func noForkRowNamesTheSystemBranchSymbol() throws {
        let root = try Self.root()
        let sources = root.appendingPathComponent("cmux-next-ios/CmuxMobileKit/Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("Fork") && line.contains("arrow.triangle.branch") {
                offenders.append("\(url.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "fork rows with arrow.triangle.branch instead of CmuxSymbol.fork: \(offenders)")
    }

    #if canImport(UIKit)
    /// The asset catalog ships the symbol (a symbol image, so it takes the text's size and weight).
    @Test func theSymbolLoads() throws {
        let image = try #require(UIImage(named: CmuxSymbol.fork, in: CmuxSymbol.bundle, with: nil))
        #expect(image.isSymbolImage)
    }
    #endif
}

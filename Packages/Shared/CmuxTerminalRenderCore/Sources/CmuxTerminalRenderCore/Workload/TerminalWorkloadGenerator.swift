public import Foundation

/// Builds workload scripts. Generated workloads are deterministic for a seed,
/// so two runs (and two devices) replay byte-identical streams.
public struct TerminalWorkloadGenerator: Sendable {
    public var seed: UInt64
    /// Corpus cases are delivered in chunks of this size (a fast network burst).
    public var corpusChunkBytes: Int
    /// Flood output is delivered in chunks of this size per frame.
    public var floodChunkBytes: Int

    public init(seed: UInt64 = 0x636D_7578, corpusChunkBytes: Int = 4096, floodChunkBytes: Int = 64 * 1024) {
        self.seed = seed
        self.corpusChunkBytes = max(corpusChunkBytes, 1)
        self.floodChunkBytes = max(floodChunkBytes, 1)
    }

    /// A corpus case from its bytes and manifest entry.
    public func script(corpus entry: TerminalCorpusManifest.Case, bytes: Data) -> TerminalWorkloadScript {
        TerminalWorkloadScript(name: "corpus:" + entry.name, cols: entry.cols, rows: entry.rows,
                               chunks: Self.split(bytes, every: corpusChunkBytes))
    }

    /// A generated workload; nil for `.corpus` (use `script(corpus:bytes:)`).
    public func script(_ workload: TerminalWorkload, cols: Int = 80, rows: Int = 24) -> TerminalWorkloadScript? {
        let cols = max(cols, 20), rows = max(rows, 8)
        switch workload {
        case .corpus: return nil
        case .flood(let bytes):
            return TerminalWorkloadScript(name: workload.id, cols: cols, rows: rows,
                                          chunks: Self.split(flood(bytes: bytes, cols: cols), every: floodChunkBytes))
        case .htop(let frames):
            var random = SplitMix64(seed: seed)
            let chunks = (0..<max(frames, 1)).map { Data(htopFrame($0, cols: cols, rows: rows, random: &random).utf8) }
            return TerminalWorkloadScript(name: workload.id, cols: cols, rows: rows, chunks: chunks)
        case .vim(let frames):
            var random = SplitMix64(seed: seed)
            var chunks = [Data(vimOpen(cols: cols, rows: rows, random: &random).utf8)]
            for frame in 0..<max(frames, 1) {
                chunks.append(Data(vimScroll(frame, cols: cols, rows: rows, random: &random).utf8))
            }
            return TerminalWorkloadScript(name: workload.id, cols: cols, rows: rows, chunks: chunks)
        }
    }

    // MARK: Generators

    private static let esc = "\u{1B}["

    private func flood(bytes: Int, cols: Int) -> Data {
        var random = SplitMix64(seed: seed)
        var out = Data()
        out.reserveCapacity(bytes + cols * 2)
        var line = 0
        let words = ["request", "GET", "/api/v1/terminals", "200", "ok", "latency", "bytes", "cache", "miss", "hit"]
        while out.count < bytes {
            line += 1
            var text = String(format: "%08d ", line)
            if line % 7 == 0 { text += Self.esc + "3\(1 + Int(random.next() % 6))m" }
            while text.count < cols - 12 { text += words[Int(random.next() % UInt64(words.count))] + " " }
            if line % 7 == 0 { text += Self.esc + "0m" }
            out.append(contentsOf: Array((text + "\r\n").utf8))
        }
        return out.prefix(bytes)
    }

    private func htopFrame(_ frame: Int, cols: Int, rows: Int, random: inout SplitMix64) -> String {
        let e = Self.esc
        var out = e + "?25l" + e + "H"
        let bar = max(cols / 2 - 8, 4)
        for cpu in 0..<4 {
            let used = Int(random.next() % UInt64(bar + 1))
            out += e + "1m\(cpu + 1)" + e + "0m[" + e + "32m" + String(repeating: "|", count: used) + e + "0m"
                + String(repeating: " ", count: bar - used) + String(format: "%3d%%]", used * 100 / bar) + e + "K\r\n"
        }
        out += e + "30;42m" + "  PID USER      CPU% MEM%   TIME+  Command".padding(toLength: cols, withPad: " ", startingAt: 0)
            + e + "0m\r\n"
        for row in 0..<(rows - 6) {
            let pid = 1000 + (row * 37 + frame) % 9000
            let cpu = Double(random.next() % 1000) / 10
            let line = String(format: "%5d %-8@ %5.1f %4.1f %3d:%02d.%02d %@", pid, "dev" as NSString, cpu,
                              Double(random.next() % 200) / 10, frame / 60, frame % 60, row,
                              "cmux-tui --session s\(row)" as NSString)
            let color = cpu > 80 ? e + "31m" : cpu > 40 ? e + "33m" : ""
            out += color + String(line.prefix(cols)) + e + "0m" + e + "K\r\n"
        }
        out += e + "7m F1Help F2Setup F3Search F9Kill F10Quit " + e + "0m" + e + "K"
        return out
    }

    private func vimOpen(cols: Int, rows: Int, random: inout SplitMix64) -> String {
        let e = Self.esc
        var out = e + "?1049h" + e + "H" + e + "2J" + e + "1;\(rows - 1)r"
        for row in 1..<rows {
            out += e + "\(row);1H" + vimLine(row, cols: cols, random: &random)
        }
        return out + vimStatus(0, cols: cols, rows: rows)
    }

    private func vimScroll(_ frame: Int, cols: Int, rows: Int, random: inout SplitMix64) -> String {
        let e = Self.esc
        // Scroll the region up one line and draw the new bottom line.
        return e + "?25l" + e + "\(rows - 1);1H" + "\n" + e + "\(rows - 1);1H"
            + vimLine(rows + frame, cols: cols, random: &random) + vimStatus(frame + 1, cols: cols, rows: rows)
    }

    private func vimLine(_ number: Int, cols: Int, random: inout SplitMix64) -> String {
        let e = Self.esc
        let keywords = ["fn", "let", "return", "if", "match", "pub", "struct"]
        let keyword = keywords[Int(random.next() % UInt64(keywords.count))]
        let body = "\(keyword) value_\(number) = compute(\(random.next() % 1000));"
        return e + "38;5;242m" + String(format: "%4d ", number) + e + "0m" + e + "38;5;175m" + keyword + e + "0m"
            + String(body.dropFirst(keyword.count).prefix(max(cols - 5 - keyword.count, 0))) + e + "K"
    }

    private func vimStatus(_ frame: Int, cols: Int, rows: Int) -> String {
        let e = Self.esc
        let status = " NORMAL  src/main.zig  line \(frame + 1)".padding(toLength: cols, withPad: " ", startingAt: 0)
        return e + "\(rows);1H" + e + "7m" + status + e + "0m" + e + "\(rows - 1);6H" + e + "?25h"
    }

    static func split(_ data: Data, every size: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: data.startIndex, to: data.endIndex, by: size).map {
            Data(data[$0..<min($0 + size, data.endIndex)])
        }
    }
}

/// SplitMix64: a small deterministic generator (same sequence on every platform).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

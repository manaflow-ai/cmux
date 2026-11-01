import Foundation

/// Names the pixels of a captured scanline by the colors learned from the window at rest: each
/// pane's own solid color, the divider line's, the background's. A pixel that matches none of
/// them is a blend (an edge off the device-pixel grid, drawn half in one color and half in the
/// next) or something the fixture did not expect; either fails the frame.
struct ScanlinePalette {
    /// Per channel, at most one 8-bit step (1/255) from a learned color. Written here, never
    /// raised: a change needs its own commit with the reason and a reviewer receipt (cmux-ad
    /// 2026-11-01, rule 5).
    static let channelTolerance = 1

    struct Run: Equatable, CustomStringConvertible {
        /// The learned label, or nil for pixels that match no learned color.
        let label: String?
        /// First device pixel of the run.
        let start: Int
        /// One past its last device pixel.
        let end: Int
        var length: Int { end - start }
        /// The label, or a name no learned color has.
        var name: String { label ?? "<unnamed>" }
        var description: String { "\(label ?? "?")[\(start)..<\(end)]" }
    }

    private(set) var entries: [(label: String, color: UInt32)] = []

    /// Learns `color` as `label`. Throws when it is within the tolerance of another label's color:
    /// the two could not be told apart.
    mutating func learn(_ label: String, _ color: UInt32) throws {
        if let clash = entries.first(where: { $0.label != label && Self.matches($0.color, color) }) {
            throw Clash(description: "\(label) (\(Self.hex(color))) cannot be told from \(clash.label) (\(Self.hex(clash.color)))")
        }
        if let known = entries.first(where: { $0.label == label }), !Self.matches(known.color, color) {
            throw Clash(description: "\(label) shows two colors at rest: \(Self.hex(known.color)) and \(Self.hex(color))")
        }
        entries.removeAll { $0.label == label }
        entries.append((label, color))
    }

    struct Clash: Error, CustomStringConvertible {
        let description: String
    }

    func label(of pixel: UInt32) -> String? {
        entries.first { Self.matches($0.color, pixel) }?.label
    }

    func runs(_ line: [UInt32]) -> [Run] {
        var runs: [Run] = []
        var start = 0
        var current = line.first.flatMap(label(of:))
        for index in line.indices.dropFirst() {
            let next = label(of: line[index])
            if next != current || (next == nil && line[index] != line[index - 1]) {
                runs.append(Run(label: current, start: start, end: index))
                start = index
                current = next
            }
        }
        if !line.isEmpty { runs.append(Run(label: current, start: start, end: line.count)) }
        return runs
    }

    static func matches(_ a: UInt32, _ b: UInt32) -> Bool {
        for shift in stride(from: 0, to: 32, by: 8) {
            let x = Int((a >> UInt32(shift)) & 0xFF), y = Int((b >> UInt32(shift)) & 0xFF)
            if abs(x - y) > channelTolerance { return false }
        }
        return true
    }

    /// BGRA as read from the capture, shown as #RRGGBB.
    static func hex(_ pixel: UInt32) -> String {
        let blue = pixel & 0xFF, green = (pixel >> 8) & 0xFF, red = (pixel >> 16) & 0xFF
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

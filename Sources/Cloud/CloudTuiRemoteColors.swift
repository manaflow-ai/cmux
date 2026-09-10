import Foundation

/// The sparse color sidecar a cmux-tui `attach-surface` stream sends beside a
/// theme-portable replay: only colors the remote PTY (or the daemon's pushed
/// defaults) authored. Every entry absent here stays whatever the local
/// Ghostty theme says.
///
/// The pane applies it by feeding the equivalent OSC sequences to its own
/// libghostty, so the renderer parses them exactly as it would have parsed the
/// PTY's original bytes.
struct CloudTuiRemoteColors: Equatable, Sendable {
    var foreground: String?
    var background: String?
    var cursor: String?
    /// Palette index (0...255) to `#rrggbb`.
    var palette: [Int: String]

    init(foreground: String? = nil, background: String? = nil, cursor: String? = nil, palette: [Int: String] = [:]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.palette = palette
    }

    /// Parses the protocol object. Unknown keys and malformed values are
    /// dropped rather than rejecting the frame, since a color is never worth
    /// losing the screen bytes it travels with.
    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        foreground = Self.hex(object["fg"])
        background = Self.hex(object["bg"])
        cursor = Self.hex(object["cursor"])
        var palette: [Int: String] = [:]
        if let entries = object["palette"] as? [String: Any] {
            for (key, value) in entries {
                guard let index = Int(key), (0...255).contains(index), let color = Self.hex(value) else { continue }
                palette[index] = color
            }
        }
        self.palette = palette
    }

    var isEmpty: Bool {
        foreground == nil && background == nil && cursor == nil && palette.isEmpty
    }

    /// OSC 10/11/12 for the special colors and OSC 4 per authored palette
    /// entry, in index order so output is deterministic. Equivalent to the
    /// delta from a terminal with no remote colors applied.
    var oscBytes: Data {
        oscDelta(from: CloudTuiRemoteColors())
    }

    /// The sidecar is a full sparse replacement, not a merge: an entry the
    /// remote PTY reset (OSC 104/110/111/112) is simply absent from the next
    /// snapshot. libghostty keeps OSC color overrides until told otherwise,
    /// so this emits the matching reset for every entry `previous` carried
    /// that `self` no longer does, and a set for every entry that is new or
    /// changed. Unchanged entries produce nothing.
    func oscDelta(from previous: CloudTuiRemoteColors) -> Data {
        var text = ""
        Self.appendSpecial(&text, set: 10, reset: 110, previous: previous.foreground, next: foreground)
        Self.appendSpecial(&text, set: 11, reset: 111, previous: previous.background, next: background)
        Self.appendSpecial(&text, set: 12, reset: 112, previous: previous.cursor, next: cursor)
        for index in Set(previous.palette.keys).union(palette.keys).sorted() {
            let before = previous.palette[index]
            let after = palette[index]
            guard before != after else { continue }
            if let after {
                text += "\u{1B}]4;\(index);\(Self.rgbSpec(after))\u{1B}\\"
            } else {
                text += "\u{1B}]104;\(index)\u{1B}\\"
            }
        }
        return Data(text.utf8)
    }

    private static func appendSpecial(_ text: inout String, set: Int, reset: Int, previous: String?, next: String?) {
        guard previous != next else { return }
        if let next {
            text += "\u{1B}]\(set);\(rgbSpec(next))\u{1B}\\"
        } else {
            text += "\u{1B}]\(reset)\u{1B}\\"
        }
    }

    private static func rgbSpec(_ hex: String) -> String {
        let digits = hex.dropFirst()
        let r = digits.prefix(2)
        let g = digits.dropFirst(2).prefix(2)
        let b = digits.dropFirst(4).prefix(2)
        return "rgb:\(r)/\(g)/\(b)"
    }

    /// Accepts only `#rrggbb`, lowercased, so the OSC text is never built from
    /// an unexpected shape.
    private static func hex(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 7, text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return text
    }
}

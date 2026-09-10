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
    /// entry, in index order so output is deterministic.
    var oscBytes: Data {
        var text = ""
        if let foreground { text += "\u{1B}]10;\(Self.rgbSpec(foreground))\u{1B}\\" }
        if let background { text += "\u{1B}]11;\(Self.rgbSpec(background))\u{1B}\\" }
        if let cursor { text += "\u{1B}]12;\(Self.rgbSpec(cursor))\u{1B}\\" }
        for index in palette.keys.sorted() {
            guard let color = palette[index] else { continue }
            text += "\u{1B}]4;\(index);\(Self.rgbSpec(color))\u{1B}\\"
        }
        return Data(text.utf8)
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

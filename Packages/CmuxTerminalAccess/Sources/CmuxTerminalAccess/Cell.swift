// SPDX-License-Identifier: MIT

/// One terminal cell. `t` is the full grapheme cluster (base + combining
/// + ZWJ + variation selectors), not a single code point. `underlineKind`
/// is `nil` when the cell has no underline (D25). `hyperlink` holds the
/// OSC 8 URI string directly per D26 (the Phase 1 Swift bridge resolves
/// ghostty's `hyperlink_id: u32` into the URI via the per-call hyperlink
/// table from ghostty patch #1).
public struct Cell: Hashable, Sendable, Codable {
    /// Grapheme cluster text for this cell.
    public let t: String
    /// East-Asian-Width / spacer state.
    public let wide: WideKind
    /// Foreground color.
    public let fg: CellColor
    /// Background color.
    public let bg: CellColor
    /// SGR-style visual attributes (bold, italic, etc.). Underline state
    /// lives in ``underlineKind`` / ``underlineColor`` (D25).
    public let attrs: Set<CellAttribute>
    /// Underline style, or `nil` when the cell is not underlined.
    public let underlineKind: UnderlineKind?
    /// Optional explicit underline color (SGR 58), or `nil` to inherit
    /// from ``fg``.
    public let underlineColor: CellColor?
    /// OSC 8 hyperlink URI (D26), or `nil` when no hyperlink is attached.
    public let hyperlink: String?
    /// Optional OSC 133 semantic region kind for this cell.
    public let semantic: SemanticKind?

    /// Creates a cell from its fields. Underline/hyperlink/semantic
    /// fields default to `nil` (i.e. absent on the wire).
    public init(
        t: String,
        wide: WideKind,
        fg: CellColor,
        bg: CellColor,
        attrs: Set<CellAttribute>,
        underlineKind: UnderlineKind? = nil,
        underlineColor: CellColor? = nil,
        hyperlink: String? = nil,
        semantic: SemanticKind? = nil
    ) {
        self.t = t
        self.wide = wide
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.underlineKind = underlineKind
        self.underlineColor = underlineColor
        self.hyperlink = hyperlink
        self.semantic = semantic
    }

    enum CodingKeys: String, CodingKey {
        case t, wide, fg, bg, attrs
        case underlineKind = "underline_kind"
        case underlineColor = "underline_color"
        case hyperlink, semantic
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(wide, forKey: .wide)
        try c.encode(fg, forKey: .fg)
        try c.encode(bg, forKey: .bg)
        try c.encode(attrs, forKey: .attrs)
        try c.encodeIfPresent(underlineKind, forKey: .underlineKind)
        try c.encodeIfPresent(underlineColor, forKey: .underlineColor)
        try c.encodeIfPresent(hyperlink, forKey: .hyperlink)
        try c.encodeIfPresent(semantic, forKey: .semantic)
    }
}

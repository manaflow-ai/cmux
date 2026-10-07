public import CmuxTheme

/// The user's terminal look on this device, as the renderer applies it: the
/// settings screen produces it, every terminal surface follows it. Client
/// state of the device, never synced.
public struct TerminalAppearance: Hashable, Sendable {
    /// Nil keeps the theme the terminal was opened with (the Mac's, or
    /// Ghostty's default).
    public var theme: ThemeInput?
    /// Nil keeps Ghostty's embedded font.
    public var fontFamily: String?
    /// Points at the default Dynamic Type size (`TerminalFontSizing.baseSize`).
    public var baseFontSize: Double
    public var followsDynamicType: Bool
    public var cursorStyle: TerminalCursorStyle
    public var cursorBlink: Bool
    /// Key bar key ids in order (setting `ios.terminal.accessoryKeys`); empty
    /// means the default bar.
    public var keyBarKeyIDs: [String]

    public init(theme: ThemeInput? = nil, fontFamily: String? = nil,
                baseFontSize: Double = TerminalFontSizing().baseSize, followsDynamicType: Bool = true,
                cursorStyle: TerminalCursorStyle = .block, cursorBlink: Bool = false,
                keyBarKeyIDs: [String] = []) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.baseFontSize = baseFontSize
        self.followsDynamicType = followsDynamicType
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.keyBarKeyIDs = keyBarKeyIDs
    }

    /// The font sizing with this appearance's base size, keeping the other limits.
    public func fontSizing(from base: TerminalFontSizing = TerminalFontSizing()) -> TerminalFontSizing {
        var sizing = base
        sizing.baseSize = min(max(baseFontSize, sizing.minimumSize), sizing.maximumSize)
        return sizing
    }
}

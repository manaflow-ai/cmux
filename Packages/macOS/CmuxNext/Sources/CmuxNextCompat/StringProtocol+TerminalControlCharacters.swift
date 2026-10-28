extension StringProtocol {
    /// Whether the text holds a control character: U+0000 to U+001F, U+007F or U+0080 to U+009F.
    /// A path cmux types into a shell (a script opened with cmux, a dropped or pasted file) must
    /// hold none: typed, Ctrl-U erases the quoted path and CR runs what follows, and no quoting
    /// makes those bytes safe in every shell (Ghostty 1.4.0, 0c234a04d).
    public var containsTerminalControlCharacter: Bool {
        unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }
}

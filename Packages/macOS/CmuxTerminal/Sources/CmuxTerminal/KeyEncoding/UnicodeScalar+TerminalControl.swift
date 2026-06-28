extension UnicodeScalar {
    /// True when this scalar represents terminal control input rather than
    /// printable text (C0 controls below U+0020, or DEL at U+007F).
    @inlinable
    public var isTerminalControlCharacter: Bool {
        value < 0x20 || value == 0x7F
    }
}

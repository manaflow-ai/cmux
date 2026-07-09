extension String {
    /// True when this AppKit text-fallback payload is printable text that should
    /// be forwarded as Ghostty key text (drops empty strings and lone control
    /// characters).
    @inlinable
    public var isForwardableGhosttyKeyText: Bool {
        guard !isEmpty else { return false }
        if count == 1, let scalar = unicodeScalars.first {
            return !scalar.isTerminalControlCharacter
        }
        return true
    }
}

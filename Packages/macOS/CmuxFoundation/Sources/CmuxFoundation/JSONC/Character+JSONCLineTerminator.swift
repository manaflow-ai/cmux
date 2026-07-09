extension Character {
    /// Whether this character begins a JSONC line-comment terminator (CR or LF).
    ///
    /// Swift treats `"\r\n"` as a single extended grapheme cluster, so comparing
    /// against `"\n"` alone misses CRLF line endings and would let a `//` line
    /// comment run to end-of-file. Match any character whose first scalar is CR
    /// or LF.
    public var isJSONCLineTerminator: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar == "\n" || scalar == "\r"
    }
}

extension FilePreviewLineIndex {
    /// Returns the UTF-16 offset of a one-based line, clamped to the document.
    ///
    /// - Parameter requestedLine: One-based line number.
    /// - Returns: The UTF-16 offset at which that line begins.
    public func offset(forLine requestedLine: Int) -> Int {
        let clamped = min(max(requestedLine, 1), lineCount)
        return storage.lineStart(at: clamped - 1) ?? 0
    }

    /// Returns the one-based line containing a UTF-16 offset.
    ///
    /// - Parameter requestedOffset: UTF-16 offset, clamped to the document.
    /// - Returns: The one-based containing line.
    public func lineNumber(containingUTF16Offset requestedOffset: Int) -> Int {
        let offset = min(max(requestedOffset, 0), loadedUTF16Length)
        return max(storage.lineStartsThrough(offset), 1)
    }
}

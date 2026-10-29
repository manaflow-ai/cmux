/// The list's row and tile bitmaps for the host's memory policy, with no platform type
/// in the API: cmux-next registers each list with its memory coordinator (CmuxNextHome's
/// `MessagesLabMemoryConsumer`). Dropping is lossless: a row on screen keeps the bitmap its layer shows,
/// and the next pass draws what is missing.
extension CmuxSidebarView {
    /// Pixel bytes of the list's cached bitmaps. Read from a counter, never a walk.
    public var bitmapBytes: Int { controller.cache.bytes }

    /// The list's cached bitmaps.
    public var bitmapCount: Int { controller.cache.count }

    /// Caps the list's bitmaps at `bytes` (MessagesLab's 40 MB until the host sets one). Frees nothing
    /// now: the next insert trims to it.
    ///
    /// - Parameter bytes: The most bytes the list keeps (negative counts as 0).
    public func setBitmapBudget(bytes: Int) {
        controller.cache.setBudget(bytes: bytes)
    }

    /// Frees the least recently used bitmaps until at most `fraction` of ``bitmapBytes`` remain; `0` frees
    /// them all. The cap stays as it is.
    ///
    /// - Parameter fraction: The share of what the list holds now to keep, 0...1 (NaN keeps all).
    public func trimBitmaps(toFraction fraction: Double) {
        controller.cache.trim(toFraction: fraction)
    }
}

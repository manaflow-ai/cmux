/// Keys a REPL session holds down in one tab, so they can be released when
/// the last session leaves the tab. Without the release the page never gets
/// their `keyup` and keeps acting as if they were held (Shift-selection,
/// a game's held arrow key).
public struct BrowserReplHeldKeys: Sendable, Equatable {
    /// Held keys in press order.
    public private(set) var strokes: [BrowserReplKeyStroke] = []

    public init() {}

    /// Records one delivered key event. A repeated key-down moves the key to
    /// the end; a key-up releases it.
    public mutating func record(_ stroke: BrowserReplKeyStroke, keyDown: Bool) {
        strokes.removeAll { $0.keyCode == stroke.keyCode }
        if keyDown { strokes.append(stroke) }
    }

    /// The held keys in release order, last pressed first, and forgets them.
    public mutating func releaseAll() -> [BrowserReplKeyStroke] {
        defer { strokes.removeAll() }
        return strokes.reversed()
    }
}

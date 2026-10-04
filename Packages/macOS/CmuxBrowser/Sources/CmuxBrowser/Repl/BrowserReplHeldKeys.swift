/// Keys REPL sessions hold down in one tab, each with the session that
/// pressed it, so a session that leaves the tab releases its own keys and
/// no other session's (a session that stays never inherits a key another
/// left held, nor loses one it holds). Without the release the page never
/// gets their `keyup` and keeps acting as if they were held
/// (Shift-selection, a game's held arrow key).
public struct BrowserReplHeldKeys: Sendable, Equatable {
    /// Held keys in press order.
    public var strokes: [BrowserReplKeyStroke] { held.map(\.stroke) }

    private var held: [(stroke: BrowserReplKeyStroke, sessionID: String)] = []

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.held.elementsEqual(rhs.held) { $0.stroke == $1.stroke && $0.sessionID == $1.sessionID }
    }

    /// Records one key event `sessionID` delivered. A repeated key-down
    /// moves the key to the end; a key-up releases it. Each session holds
    /// its own keys (its modifiers apply only to its own input), so another
    /// session's press or release of the same key leaves this one's held.
    public mutating func record(_ stroke: BrowserReplKeyStroke, keyDown: Bool, sessionID: String = "") {
        held.removeAll { $0.stroke.keyCode == stroke.keyCode && $0.sessionID == sessionID }
        if keyDown { held.append((stroke, sessionID)) }
    }

    /// The keys `sessionID` holds, in release order (last pressed first),
    /// and forgets them; the other sessions' keys stay held.
    public mutating func releaseAll(heldBy sessionID: String) -> [BrowserReplKeyStroke] {
        let released = held.filter { $0.sessionID == sessionID }.map(\.stroke)
        held.removeAll { $0.sessionID == sessionID }
        return released.reversed()
    }

    /// The held keys in release order, last pressed first, and forgets them.
    public mutating func releaseAll() -> [BrowserReplKeyStroke] {
        defer { held.removeAll() }
        return strokes.reversed()
    }
}

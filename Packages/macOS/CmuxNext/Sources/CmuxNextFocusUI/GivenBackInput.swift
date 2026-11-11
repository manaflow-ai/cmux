public import Foundation

/// Keys the daemon gave back from a terminal creation that did not take them (cx-wb5.78,
/// `terminal-input-unclaimed`), held until a terminal of the window they were typed in can take
/// them: its focused one that is not being created itself (a give-back can arrive while the failed
/// creation's view still has focus). Never a terminal of another window (Lawrence 2026-10-23:
/// "i type in one window of cmux, but the text appears in another window"); keys of no known
/// window are dropped. Keys held longer than `limit` are dropped, never typed: much later they
/// would land in a terminal the user did not type them for (and may hold a Return).
///
/// Keys of a creation the person closed (``creationClosed(terminal:)``) are dropped too, held
/// already or given back later: the person threw that pane away with what they typed in it, and
/// the close moves the focus to a neighbour terminal, which must not get them.
@MainActor
public final class GivenBackInput {
    /// The app's one holder.
    public static let shared = GivenBackInput()
    /// The held keys in the order given back, each piece with the creating terminal it came from
    /// (nil: not named).
    private var held: [(terminal: String?, bytes: Data)] = []
    /// The creating terminals the person closed, oldest first (the last ``closedLimit``): a
    /// give-back from one is dropped. The daemon gives a creation's keys back once, some seconds
    /// after they were typed, so a short list covers every close that can still get one.
    private var closed: [String] = []
    static let closedLimit = 32
    /// The window the held keys were typed in.
    private var window: String?
    private var since: ContinuousClock.Instant?
    private let limit: Duration
    private let now: () -> ContinuousClock.Instant

    public init(limit: Duration = .seconds(3), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.limit = limit
        self.now = now
    }

    /// Adds `more`, typed in `window`, then hands everything held to `target`, a terminal in
    /// `window`, when there is one and the held keys were typed in that window.
    ///
    /// - Parameters:
    ///   - more: Keys to hold, typed in `window`; with no `window` they are dropped.
    ///   - terminal: The creating terminal `more` was typed in; keys of one the person closed are dropped.
    ///   - window: The window `more` was typed in, and the window `target` is in.
    ///   - target: Writes to the focused terminal of `window`; nil while there is none.
    public func deliver(adding more: Data = Data(), from terminal: String? = nil, window: String?,
                        to target: (@MainActor (Data) -> Void)?) {
        if let since, now() - since > limit { drop() }
        if !more.isEmpty, let window, terminal.map({ !closed.contains($0) }) ?? true {
            if self.window != window { drop() }
            if held.isEmpty { since = now() }
            self.window = window
            held.append((terminal, more))
        }
        guard !held.isEmpty, let window, window == self.window, let target else { return }
        target(held.reduce(into: Data()) { $0.append($1.bytes) })
        drop()
    }

    /// The person closed the pane of creating terminal `terminal` before it started: the keys it
    /// gave back are dropped now, and those it gives back later are dropped when they come.
    public func creationClosed(terminal: String) {
        held.removeAll { $0.terminal == terminal }
        if held.isEmpty { drop() }
        closed.removeAll { $0 == terminal }
        closed.append(terminal)
        if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
    }

    private func drop() {
        held = []
        window = nil
        since = nil
    }
}

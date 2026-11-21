#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings

/// When a new browser tab's omnibar first took the keyboard and first showed the keys typed right after
/// the key that opened it (`debug.new_tab` `bench_create new_browser` with `type`).
///
/// A bench's waits run one at a time, so each wait's condition calls ``note(editing:text:at:)`` on every tick:
/// each mark is the first frame it held at, never the start of a later wait.
@MainActor
public final class OmnibarFirstHolds {
    /// The keys typed after the key, or nil when the run types nothing and reads no omnibar.
    public let typed: String?
    /// Ms after the key at which the omnibar first edited as the window's first responder.
    public private(set) var focus: Double?
    /// Ms after the key at which the focused omnibar first showed exactly ``typed``.
    public private(set) var shown: Double?

    /// - Parameter typed: the keys typed after the key; nil reads nothing.
    public init(typed: String?) { self.typed = typed }

    /// Both marks are in (or the run reads none).
    public var done: Bool { typed == nil || (focus != nil && (shown != nil || typed?.isEmpty == true)) }

    /// Records the marks that hold now.
    /// - Parameters:
    ///   - editing: the new tab's omnibar edits as first responder (nil: no omnibar shows yet).
    ///   - text: what that omnibar shows.
    ///   - at: ms after the key.
    public func note(editing: Bool?, text: String?, at milliseconds: Double) {
        guard let typed, editing == true else { return }
        if focus == nil { focus = milliseconds }
        if shown == nil, !typed.isEmpty, text == typed { shown = milliseconds }
    }

    /// `focus_ms`, `typed_ms`, and what the omnibar holds and whether it still edits at the run's end
    /// (`typed_text`: a key lost, or typed twice, shows here).
    public func report(editing: Bool?, text: String?) -> JSONValue {
        guard typed != nil else { return .null }
        return .object(["focus_ms": focus.map { .number($0) } ?? .null, "typed_ms": shown.map { .number($0) } ?? .null,
                        "typed_text": text.map { .string($0) } ?? .null, "focused_at_end": editing.map { .bool($0) } ?? .null])
    }
}
#endif

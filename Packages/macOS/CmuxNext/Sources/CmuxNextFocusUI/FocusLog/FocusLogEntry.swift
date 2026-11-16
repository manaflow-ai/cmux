public import Foundation

/// One line of the focus log (``FocusLog``): a keyboard focus change, what it went from and
/// to, what caused it, and the call stack that made it. Never carries typed text.
public nonisolated struct FocusLogEntry: Codable, Sendable, Hashable {
    /// What changed.
    public enum Kind: String, Codable, Sendable {
        /// `makeFirstResponder` moved a cmux window's first responder.
        case responder
        /// The window refused a `makeFirstResponder` (a page asking for the keys by itself).
        case refused
        /// The first responder changed with no `makeFirstResponder` (a focused view left the
        /// window): seen by key-value observation, or at the next key-down.
        case silent
        /// Another window of the app became key (a page window, a panel, another cmux window).
        case key
        /// A cmux page's text input lost the keyboard inside its page (the page stayed focused).
        case pageBlur = "page_blur"
    }

    /// Wall-clock time (ISO 8601 with milliseconds).
    public var time: String
    /// System uptime in seconds, to order lines against other logs.
    public var uptime: Double
    /// What changed.
    public var kind: Kind
    /// The cmux window (`WindowState.id`), or the class of another window.
    public var window: String?
    /// What had the keyboard before (a responder's place and class, or a window).
    public var from: String?
    /// What has it after.
    public var to: String?
    /// The input event dispatched while it happened: `keyboard`, `mouse`, or `none`.
    public var input: String
    /// Milliseconds since the last key or click the person made (nil: none yet).
    public var sinceInputMs: Int?
    /// `focus-model` when the window's focus coordinator applied it, else `direct`.
    public var by: String
    /// The origin of the action run it happened in (`cli`, `agent`, `user`, ...), if any.
    public var run: String?
    /// The ``FocusRoute`` it came through (`origin Module/File.swift:line reason`), or `unrouted`
    /// for a direct `makeFirstResponder` / `makeKey` (a page's own request, code not yet moved).
    public var route: String?
    /// True when no key or click caused it and it took the keyboard from a typing target.
    public var suspect: Bool
    /// More about the change (a page's element, the stack's source).
    public var detail: String?
    /// The call stack, innermost first, symbolicated off the main thread.
    public var stack: [String]

    enum CodingKeys: String, CodingKey {
        case time, uptime, kind, window, from, to, input, by, run, route, suspect, detail, stack
        case sinceInputMs = "since_input_ms"
    }
}

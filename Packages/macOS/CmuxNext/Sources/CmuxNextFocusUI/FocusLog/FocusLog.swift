public import AppKit
import CmuxNextActions
public import CmuxNextDesign
import WebKit

/// The focus log (`tunable.diagnostics.focusLog`, plans/cmux-next/focus-loss-AUDIT.md): while it
/// is on, every keyboard focus change of the app's windows is written with its cause and call
/// stack, so a focus loss in a real session names the code behind it.
///
/// The app's window reports to it: each `makeFirstResponder` it accepts or refuses
/// (``responderChanged(in:from:to:refused:byFocusModel:)``), each time it becomes or resigns key
/// (``keyChanged(_:becameKey:)``), and each key-down (``noteInput(_:)``), which also catches a
/// first responder that changed with no `makeFirstResponder` (a focused view removed from its
/// window). A cmux page reports its text input losing the keyboard inside the page
/// (``pageInputBlurred(window:detail:)``). Each line names the ``FocusRoute`` the move came
/// through (`unrouted` for a direct call).
///
/// The newest 200 changes are kept in memory whether the log is on or not, without stacks, for
/// `cmux app call debug.focus` (``recent(limit:)``); the file and the stacks are written only while
/// the log is on. One log per app.
///
/// ```swift
/// let log = FocusLog(writer: FocusLogWriter(directory: temporaryFolder, symbolicate: { $0.map { "\($0)" } }),
///                    context: .init(), enabled: { true })
/// window.focusLog = log
/// ```
@MainActor
public final class FocusLog {
    /// What the app knows about its windows, which this package cannot see.
    public struct Context {
        /// The focus model's name for a responder of a window (`content(pane: …)`), nil when the
        /// window is not a cmux window.
        public var classify: @MainActor (NSResponder, NSWindow) -> String?
        /// A cmux window's id (`WindowState.id`), nil for another window.
        public var windowName: @MainActor (NSWindow) -> String?
        /// The input event dispatched now: `keyboard`, `mouse`, or anything else for none.
        public var currentInput: @MainActor () -> String

        /// - Parameters:
        ///   - classify: The focus model's classification (defaults to none).
        ///   - windowName: A cmux window's id (defaults to none).
        ///   - currentInput: The event being dispatched (defaults to `none`).
        public init(classify: @escaping @MainActor (NSResponder, NSWindow) -> String? = { _, _ in nil },
                    windowName: @escaping @MainActor (NSWindow) -> String? = { _ in nil },
                    currentInput: @escaping @MainActor () -> String = { "none" }) {
            self.classify = classify
            self.windowName = windowName
            self.currentInput = currentInput
        }
    }

    /// A line waiting for the writer, or a caller waiting for every line before it.
    nonisolated private enum Pending: Sendable {
        case line(FocusLogEntry, [UInt])
        case flush(CheckedContinuation<Void, Never>)
    }

    private let writer: FocusLogWriter
    private let context: Context
    private let enabled: () -> Bool
    private let pending: AsyncStream<Pending>.Continuation
    /// The responder each reporting window had last, to see a change no call reported.
    private var lastResponder: [ObjectIdentifier: (responder: ObjectIdentifier?, description: String)] = [:]
    /// The uptime of the person's last key or click.
    private var lastInput: TimeInterval?
    /// The responder the person's last plain key-down (no Command or Control) went to, and when.
    private var lastTyped: (responder: ObjectIdentifier, uptime: TimeInterval)?
    /// The newest changes, oldest first (at most ``recentLimit``), for ``recent(limit:)``.
    private var ring: [FocusLogEntry] = []
    /// How many changes ``recent(limit:)`` keeps.
    public static let recentLimit = 200

    /// - Parameters:
    ///   - writer: Where lines go (the app's log folder; a temporary one in tests).
    ///   - context: The app's names for responders and windows, and the input event dispatched now.
    ///   - enabled: Whether the log records (nil: `tunable.diagnostics.focusLog`).
    public init(writer: FocusLogWriter, context: Context, enabled: (() -> Bool)? = nil) {
        self.writer = writer
        self.context = context
        self.enabled = enabled ?? { FocusLogTunables.enabled.value }
        // Focus changes come a few a second at most; past 512 waiting lines the oldest are dropped.
        let (stream, continuation) = AsyncStream<Pending>.makeStream(bufferingPolicy: .bufferingNewest(512))
        pending = continuation
        // task-owner: the writer's queue for the log's life (finished in deinit): lines are written in the order they happened.
        Task.detached(priority: .utility) {
            for await item in stream {
                switch item {
                case .line(let entry, let addresses): await writer.append(entry, addresses: addresses)
                case .flush(let done): done.resume()
                }
            }
        }
    }

    nonisolated deinit { pending.finish() }

    /// Whether lines are written now.
    public var isEnabled: Bool { enabled() }

    /// The newest changes, oldest first, at most `limit` (kept while the log is off too, without
    /// stacks).
    public func recent(limit: Int = FocusLog.recentLimit) -> [FocusLogEntry] { Array(ring.suffix(max(0, limit))) }

    /// Whether the person typed into `responder` (a key-down with no Command or Control) in the
    /// last `seconds`: ``ResponderMoveGate`` refuses a ``FocusRoute/Origin/system`` move away from it.
    public func typed(into responder: NSResponder?, within seconds: TimeInterval) -> Bool {
        guard let responder, let lastTyped, lastTyped.responder == ObjectIdentifier(responder) else { return false }
        return ProcessInfo.processInfo.systemUptime - lastTyped.uptime <= seconds
    }

    /// The file lines go to.
    public nonisolated var url: URL? { writer.url }

    /// Returns once every line recorded before it is on disk (tests and `cmux` readers).
    public func flush() async {
        await withCheckedContinuation { pending.yield(.flush($0)) }
    }

    // MARK: Hooks

    /// `window` moved its first responder from `from` to `to` (through `route`), or refused the move.
    ///
    /// - Parameters:
    ///   - window: The window whose `makeFirstResponder` ran.
    ///   - from: The first responder before the call.
    ///   - to: The first responder after it (the asked-for one when refused).
    ///   - refused: The window refused the move.
    ///   - byFocusModel: The window's focus model applied it.
    ///   - route: The route it came through (nil: a direct call).
    public func responderChanged(in window: NSWindow, from: NSResponder?, to: NSResponder?, refused: Bool, byFocusModel: Bool,
                                 route: FocusRoute? = nil) {
        if !refused, from === to { return }
        let fromText = describe(from, in: window)
        let toText = describe(to, in: window)
        if !refused { remember(to, toText, in: window) }
        record(kind: refused ? .refused : .responder, window: window, from: fromText, to: toText, byFocusModel: byFocusModel,
               route: route, takesFromTyping: !refused && Self.isTypingTarget(from) && !Self.isTypingTarget(to), detail: nil)
    }

    /// `window` became or resigned key. A resign's stack names the code that made another window
    /// key (a Chromium page window, a panel); the other window is named when it is known.
    public func keyChanged(_ window: NSWindow, becameKey: Bool, route: FocusRoute? = nil) {
        let other = becameKey ? nil : NSApp.keyWindow.flatMap { $0 === window ? nil : $0 }
        record(kind: .key, window: window, from: becameKey ? other.map(describeWindow) : describeWindow(window),
               to: becameKey ? describeWindow(window) : other.map(describeWindow) ?? "another window",
               byFocusModel: false, route: route, takesFromTyping: !becameKey && Self.isTypingTarget(window.firstResponder),
               detail: becameKey ? "became key" : "resigned key")
    }

    /// Every input event the app dispatches. A key-down checks that the key window's first
    /// responder is the one last reported: a change no `makeFirstResponder` reported (a focused
    /// view removed from its window) shows here, before the key goes nowhere.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - window: The window it goes to; nil takes the event's window, else the key window.
    ///     A test passes its window: an event made for a window that is not on screen has none.
    public func noteInput(_ event: NSEvent, in window: NSWindow? = nil) {
        switch event.type {
        case .keyDown:
            let uptime = ProcessInfo.processInfo.systemUptime
            lastInput = uptime
            let target = window ?? event.window ?? NSApp.keyWindow
            if event.modifierFlags.isDisjoint(with: [.command, .control]), let responder = target?.firstResponder {
                lastTyped = (ObjectIdentifier(responder), uptime)
            }
            guard let window = target, let known = lastResponder[ObjectIdentifier(window)] else { return }
            let now = window.firstResponder
            guard known.responder != now.map(ObjectIdentifier.init) else { return }
            let toText = describe(now, in: window)
            remember(now, toText, in: window)
            record(kind: .silent, window: window, from: known.description, to: toText, byFocusModel: false,
                   takesFromTyping: known.description.hasSuffix(" typing") && !Self.isTypingTarget(now),
                   detail: "seen at a key-down", unprompted: true, stack: false)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lastInput = ProcessInfo.processInfo.systemUptime
        default: break
        }
    }

    /// A cmux page's text input lost the keyboard with no key or click, while its page kept or
    /// lost it (the page's own report, `detail` its words).
    public func pageInputBlurred(window: NSWindow?, detail: String) {
        record(kind: .pageBlur, window: window, from: "page text input", to: nil, byFocusModel: false, takesFromTyping: true,
               detail: detail, unprompted: true, stack: false)
    }

    // MARK: Recording

    private func remember(_ responder: NSResponder?, _ description: String, in window: NSWindow) {
        lastResponder[ObjectIdentifier(window)] = (responder.map(ObjectIdentifier.init), description)
    }

    private func record(kind: FocusLogEntry.Kind, window: NSWindow?, from: String?, to: String?, byFocusModel: Bool,
                        route: FocusRoute? = nil, takesFromTyping: Bool, detail: String?, unprompted known: Bool? = nil, stack: Bool = true) {
        let input = context.currentInput()
        let now = ProcessInfo.processInfo.systemUptime
        let since = lastInput.map { Int((now - $0) * 1000) }
        // No key or click is handled now, and none came in the last half second (a click's async follow-up).
        let unprompted = known ?? (input != "keyboard" && input != "mouse" && (since ?? .max) > 500)
        let entry = FocusLogEntry(
            time: Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), uptime: now, kind: kind,
            window: window.map(windowID), from: from, to: to, input: input, sinceInputMs: since,
            by: byFocusModel ? "focus-model" : "direct", run: ActionRunScope.current.map { String(describing: $0.origin) },
            route: route?.description ?? "unrouted",
            suspect: unprompted && takesFromTyping, detail: detail, stack: [])
        ring.append(entry)
        if ring.count > Self.recentLimit { ring.removeFirst(ring.count - Self.recentLimit) }
        guard isEnabled else { return }
        // The stack of this change, innermost first, without this log's own two frames.
        let addresses = stack ? Array(Thread.callStackReturnAddresses.dropFirst(2).prefix(40).map(\.uintValue)) : []
        pending.yield(.line(entry, addresses))
    }

    // MARK: Descriptions

    /// The responder's place (the focus model's name in a cmux window), its class, and `typing`
    /// when keys typed there go into a text input, a terminal or a page.
    private func describe(_ responder: NSResponder?, in window: NSWindow) -> String {
        guard let responder else { return "none" }
        if responder === window { return "window" }
        var parts = [context.classify(responder, window), String(describing: type(of: responder))].compactMap(\.self)
        if Self.isTypingTarget(responder) { parts.append("typing") }
        return parts.joined(separator: " ")
    }

    private func describeWindow(_ window: NSWindow) -> String {
        var text = String(describing: type(of: window))
        if let name = context.windowName(window) { text += " \(name)" }
        if WindowOverlayHost.isPageWindow(window), let parent = window.parent { text += " page of \(windowID(parent))" }
        return text + " (\(describe(window.firstResponder, in: window)))"
    }

    private func windowID(_ window: NSWindow) -> String {
        if let name = context.windowName(window) { return name }
        if let parent = window.parent, let name = context.windowName(parent) { return name + " page" }
        return String(describing: type(of: window))
    }

    /// Keys typed into it reach a text input, a terminal or a page.
    static func isTypingTarget(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view is NSText || view is NSTextField || view is WKWebView || view is any NSTextInputClient
    }
}

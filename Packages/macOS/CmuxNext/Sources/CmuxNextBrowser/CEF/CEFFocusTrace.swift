import AppKit
import QuartzCore

/// Who asked a Chromium page for focus, for `debug.cef` `focus_log` (diagnostics only). A caller outside the browser
/// module (the focus applier, the omnibar) names itself around its `setFocused` call; the trace reads it there.
public enum BrowserFocusCaller {
    /// Runs `body` with `caller` as the reason a page's focus changes.
    @discardableResult
    @MainActor public static func with<T>(_ caller: String, _ body: () -> T) -> T {
        let trace = CEFRuntime.shared.focusTrace
        let outer = trace.caller
        trace.caller = caller
        defer { trace.caller = outer }
        return body()
    }

    /// A focus decision that changed nothing (`debug.cef` `focus_log`).
    @MainActor public static func note(_ text: String) { CEFRuntime.shared.focusTrace.note(nil, text) }
}

/// Every change to a Chromium page's focus, in order (`debug.cef` `focus_log`; approach 5, off-screen pages: what turns
/// a page's focus off): cmux's SetFocus calls with their caller, Chromium's OnSetFocus asks and the answers,
/// OnGotFocus and OnTakeFocus, main frame commits, pages shown and hidden, presses, windows becoming key
/// (`ChromiumWindowGuard`'s report), and on each line about a page its window's first responder and key state. A ring
/// of the newest lines; each starts with a sequence number, so a reader takes the lines after the last one it saw.
/// Diagnostics only: nothing reads it to decide anything.
@MainActor final class CEFFocusTrace {
    private(set) var lines: [String] = []
    private var sequence = 0
    private let capacity: Int
    private let start = CACurrentMediaTime()
    /// The caller around the running `setFocused` call (`BrowserFocusCaller.with`), nil outside one.
    var caller: String?

    init(capacity: Int = 240) { self.capacity = capacity }

    /// Adds a line: the time in ms since launch, the browser, the event, its caller and, with `view`, its window's first
    /// responder and key state.
    func note(_ browser: Int32?, _ event: String, by caller: String? = nil, view: NSView? = nil) {
        sequence += 1
        var line = "\(sequence) t=\(String(format: "%.1f", (CACurrentMediaTime() - start) * 1000))"
        if let browser { line += " b=\(browser)" }
        line += " " + event
        if let caller = caller ?? self.caller { line += " by=\(caller)" }
        if let window = view?.window { line += " " + Self.state(of: window, page: view) }
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    /// The window's first responder (`(this page)` when it is `page` or inside it, as an in-tree page's Chromium view
    /// is), number, key and the app's active state.
    static func state(of window: NSWindow, page: NSView?) -> String {
        let responder = window.firstResponder
        let name = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let inside = page.map { page in (responder as? NSView).map { $0 === page || $0.isDescendant(of: page) } ?? false } ?? false
        let mine = inside ? "(this page)" : ""
        return "fr=\(name)\(mine) win=#\(window.windowNumber) key=\(window.isKeyWindow) app_active=\(NSApp.isActive)"
    }
}

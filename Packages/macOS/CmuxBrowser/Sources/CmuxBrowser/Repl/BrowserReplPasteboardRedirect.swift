public import AppKit
import Darwin
import ObjectiveC
public import WebKit

/// Runs WebKit's own Copy, Cut and Paste editing commands against a REPL
/// tab's private pasteboard instead of the system clipboard.
///
/// WebKit has no per-web-view pasteboard: WebCore's Copy, Cut and Paste
/// always name the general pasteboard (`Pasteboard::createForCopyAndPaste`
/// takes no name), and the UI process answers the web process's pasteboard
/// IPC through `WebCore::PlatformPasteboard`, which looks the pasteboard up
/// by name (`+[NSPasteboard pasteboardWithName:]`) on the main thread, later
/// than the synchronous call. (`-[WKWebView readSelectionFromPasteboard:]`
/// takes a pasteboard and fires a trusted `paste`, but it blocks the main
/// thread on a synchronous IPC for up to 20 s while the page's handler runs,
/// and nothing like it exists for Copy or Cut.) So the redirect is narrowed
/// by caller and by time:
///
/// - Only a lookup of the general pasteboard's name made by WebKit's own code
///   (the nearest caller outside this module is WebCore or WebKit) gets the
///   tab's pasteboard. `NSPasteboard.general` and lookups by any other code,
///   such as the terminal, always get the system pasteboard.
///   `+[NSPasteboard generalPasteboard]` does not go through the hooked
///   lookup at all; WebKit's Copy, Cut and Paste do not use it.
/// - The redirect lasts from the start of the command until WebKit reports it
///   done or until the timeout, whichever comes first. A page that keeps the
///   command running longer (a handler that loops; dialogs from the tab are
///   answered at once by the caller) has its web content process ended at
///   the timeout, in the same main-thread turn that ends the redirect, so
///   nothing it does later reaches any pasteboard: ending the process
///   invalidates WebKit's connection to it, and WebKit drops the messages
///   that process sent but WebKit had not yet handled. Without that, a Copy
///   or Cut the page finishes late would write the system clipboard, where a
///   hostile page could plant a command for the person's next terminal paste.
///   The caller decides whether the process may be ended (it must belong only
///   to tabs a session created); when it may not, the command does not start
///   (`unavailable`), and when that changes during the command, the redirect
///   stays until WebKit reports the command done or one more timeout passes
///   (`timedOutStillRunning`), when the process is ended regardless. A
///   caller that stops waiting (its task is cancelled) changes none of this:
///   the timeout it is told about is the one that happened.
/// - A Paste's late reads would find nothing anyway: WebKit grants a Paste's
///   web process access to the general pasteboard at the command's start, by
///   the change count it sees then, which is the tab pasteboard's, and
///   refuses later reads while the general pasteboard's change count
///   differs. `perform` runs a Paste only while the tab pasteboard's count is
///   below the system's, so the system's, which only grows, never matches it.
/// - One command runs at a time in the whole app, not one per tab: WebKit's
///   lookups do not say which web view they serve, so two tabs' commands in
///   flight together would read and write each other's pasteboards. A command
///   waits up to its timeout for the one before it, then gets its own
///   timeout; it waits only while the earlier command is in flight, which is
///   at most its timeout, or two after a `timedOutStillRunning`. One that cannot
///   start in time does not run (`busy`, naming the tab it waited for), and
///   nothing is redirected for it while it waits.
///
/// Residual risk: while a command is in flight (milliseconds, at most its
/// timeout), a person pasting or copying in another web view of this process
/// gets or fills the tab's pasteboard, and so does app code that WebKit
/// calls back into (a delegate) if it looks up the general pasteboard by
/// name. A copy made that way lands on the tab's clipboard. The same holds
/// after a `timedOutStillRunning` until WebKit finishes, at most one more
/// timeout. The caller test errs
/// toward WebKit: should WebKit's pasteboard code move, its lookups still
/// come from a WebKit image and stay redirected, unless it moves to
/// `+generalPasteboard`, which the WebKit tests catch as a change of the
/// system pasteboard's change count. Writes a page's own scripts make (the
/// asynchronous Clipboard API, `execCommand("copy")`) are not commands and
/// are not redirected; ``BrowserReplPageClipboard`` handles those.
public enum BrowserReplPasteboardRedirect {
    /// How one command ended.
    public enum Outcome: Equatable, Sendable {
        /// WebKit reported the command done within the timeout; the tab's
        /// pasteboard holds what WebKit wrote during the command.
        case completed
        /// WebKit had not reported the command done within the timeout, so
        /// the web content process that ran it was ended at the timeout. The
        /// redirect has ended; the tab's pasteboard is no longer reachable
        /// and may be released at once.
        case timedOut
        /// WebKit had not reported the command done within the timeout and
        /// its web content process could not be ended then. WebKit's lookups
        /// of the general pasteboard keep getting the tab's pasteboard until
        /// WebKit reports the command done or one more timeout passes, when
        /// the web content is ended regardless; so nothing it writes late
        /// reaches the system pasteboard. The redirect then empties and
        /// releases that pasteboard, and the caller must not.
        case timedOutStillRunning
        /// An earlier command, from the tab the caller named `tab`, was still
        /// unfinished when this one's wait ended; this one did not start.
        case busy(tab: String)
        /// The pasteboard lookup or WebKit's editing-command or
        /// process-ending SPI is missing, the caller may not end the web
        /// content process, or a Paste could not be kept from reading the
        /// system pasteboard late (see the type's documentation); the
        /// command did not start.
        case unavailable
    }

    nonisolated(unsafe) private static var target: NSPasteboard?
    private static let lock = NSLock()
    @MainActor private static var installed = false
    /// The command WebKit has not reported done, within or past its timeout.
    @MainActor private static var unfinished: Command?

    /// Installs the process-wide `+[NSPasteboard pasteboardWithName:]` hook
    /// once. Returns `false` when the method is missing.
    @MainActor
    public static func install() -> Bool {
        if installed { return true }
        let selector = NSSelectorFromString("pasteboardWithName:")
        guard let method = class_getClassMethod(NSPasteboard.self, selector) else { return false }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSPasteboard
        let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        let replacement: @convention(block) @Sendable (AnyObject, NSString) -> NSPasteboard = { cls, name in
            redirectedLookup(of: name as String) ?? original(cls, selector, name)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        installed = true
        return true
    }

    private static let editCommandSelector = NSSelectorFromString("_executeEditCommand:argument:completion:")
    private static let endWebContentSelector = NSSelectorFromString("_killWebContentProcessAndResetState")

    /// Runs WebKit's `command` (`Copy`, `Cut` or `Paste`) in `webView` with
    /// `pasteboard` standing in for the general pasteboard. If WebKit has
    /// not finished it within `timeout`, `webView`'s web content process is
    /// ended (see the type's documentation).
    ///
    /// - Parameters:
    ///   - tab: names the tab in a later command's `busy`.
    ///   - grace: how long past `timeout` a command whose web content could
    ///     not be ended keeps running before it is ended regardless;
    ///     `timeout` when `nil`.
    ///   - systemChangeCount: the system pasteboard's change count, read when
    ///     `nil`. A Paste runs only while `pasteboard`'s count is below it.
    ///   - mayEndWebContent: whether `webView`'s web content process may be
    ///     ended; asked before the command starts (`false` there makes it
    ///     `unavailable`) and again at the timeout. When it says no at the
    ///     timeout, the process is ended one more timeout later anyway.
    ///     Ending it ends every page in that process. `webView` is held
    ///     until then, also when its tab closes.
    ///   - whenWebKitFinishes: called once, when WebKit reports the command
    ///     done or its process is ended, or at once when it did not start.
    @MainActor
    public static func perform(
        _ command: String,
        in webView: WKWebView,
        pasteboard: NSPasteboard,
        tab: String = "",
        timeout: Duration = .seconds(5),
        grace: Duration? = nil,
        systemChangeCount: Int? = nil,
        mayEndWebContent: @escaping @MainActor () -> Bool = { true },
        whenWebKitFinishes: @escaping @MainActor () -> Void = {}
    ) async -> Outcome {
        guard webView.responds(to: editCommandSelector),
              webView.responds(to: endWebContentSelector),
              command != "Paste" || pasteboard.changeCount < (systemChangeCount ?? NSPasteboard.general.changeCount),
              mayEndWebContent()
        else {
            whenWebKitFinishes()
            return .unavailable
        }
        var askedToEnd = 0
        return await run(
            on: pasteboard,
            tab: tab,
            timeout: timeout,
            grace: grace,
            endWebContent: {
                // At the timeout the caller decides; one timeout later the
                // web content is ended regardless.
                askedToEnd += 1
                guard askedToEnd > 1 || mayEndWebContent() else { return false }
                return endWebContent(of: webView)
            },
            whenFinished: whenWebKitFinishes
        ) { done in
            typealias Completion = @convention(block) (Bool) -> Void
            typealias Function = @convention(c) (AnyObject, Selector, NSString, NSString?, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: editCommandSelector), to: Function.self)
            let completion: Completion = { _ in MainActor.assumeIsolated { done() } }
            function(webView, editCommandSelector, command as NSString, "" as NSString, completion)
        }
    }

    /// Ends `webView`'s web content process at once (WebKit's
    /// `_killWebContentProcessAndResetState`): WebKit stops handling that
    /// process's messages before this returns and reports the termination to
    /// the navigation delegate. Returns `false` when the SPI is missing.
    @MainActor
    public static func endWebContent(of webView: WKWebView) -> Bool {
        guard webView.responds(to: endWebContentSelector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(webView.method(for: endWebContentSelector), to: Function.self)
        function(webView, endWebContentSelector)
        return true
    }

    /// Runs one command with `pasteboard` standing in for the general
    /// pasteboard for WebKit's lookups. `invoke` starts the command and calls
    /// its argument when WebKit reports the command done. The command waits
    /// up to `timeout` on `clock` for an earlier unfinished one, then gets
    /// its own `timeout`. If WebKit has not reported it done by then,
    /// `endWebContent` is called in the same main-actor turn; when it returns
    /// `true` the redirect ends there (`timedOut`). Otherwise
    /// (`timedOutStillRunning`) the redirect lasts until WebKit reports the
    /// command done or `grace` (one more `timeout` when `nil`) passes, when
    /// `endWebContent` is called again (the caller then ends the web content
    /// regardless) and the redirect ends whatever it returns. Cancelling the caller's task
    /// shortens none of these waits. `whenFinished` is called once, when
    /// `invoke`'s argument is called or the web content is ended, or at once
    /// when the command does not start.
    @MainActor
    public static func run<C: Clock>(
        on pasteboard: NSPasteboard,
        tab: String = "",
        timeout: Duration,
        grace: Duration? = nil,
        clock: C = ContinuousClock(),
        endWebContent: @escaping @MainActor () -> Bool,
        whenFinished: @escaping @MainActor () -> Void = {},
        invoke: (_ done: @escaping @MainActor () -> Void) -> Void
    ) async -> Outcome where C.Duration == Duration {
        guard install() else {
            whenFinished()
            return .unavailable
        }
        let waitDeadline = clock.now.advanced(by: timeout)
        while let earlier = unfinished {
            guard await earlier.finished.wait(until: waitDeadline, clock: clock, honoringCancellation: false) else {
                whenFinished()
                return .busy(tab: earlier.tab)
            }
        }
        let command = Command(pasteboard: pasteboard, tab: tab, whenFinished: whenFinished)
        unfinished = command
        setTarget(pasteboard)
        let deadline = clock.now.advanced(by: timeout)
        invoke { finish(command) }
        if await command.finished.wait(until: deadline, clock: clock, honoringCancellation: false) { return .completed }
        // Past the timeout. Until this turn ends nothing else runs on the
        // main thread, so WebKit handles no more of the page's pasteboard
        // messages before its process is gone.
        if command.finished.isSignaled { return .completed }
        if endWebContent() {
            // WebKit may already have reported the command done while it
            // ended the process; `finish` runs once either way.
            finish(command)
            return .timedOut
        }
        command.releasesPasteboardWhenFinished = true
        let bound = deadline.advanced(by: grace ?? timeout)
        Task { @MainActor in
            if await command.finished.wait(until: bound, clock: clock, honoringCancellation: false) { return }
            // The same turn again: the web content is gone before WebKit
            // could handle another of its messages, and the redirect ends.
            _ = endWebContent()
            finish(command)
        }
        return .timedOutStillRunning
    }

    /// The pasteboard a lookup of the pasteboard named `name` gets instead
    /// of the system's, or `nil` for the system's: the tab's pasteboard for
    /// a lookup of the general pasteboard by WebKit while a command is in
    /// flight.
    public static func redirectTarget(forLookupOf name: String, fromWebKit: Bool) -> NSPasteboard? {
        guard fromWebKit, name == NSPasteboard.Name.general.rawValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    private static func redirectedLookup(of name: String) -> NSPasteboard? {
        lock.lock()
        let inFlight = target != nil
        lock.unlock()
        guard inFlight, name == NSPasteboard.Name.general.rawValue else { return nil }
        return redirectTarget(forLookupOf: name, fromWebKit: lookupComesFromWebKit())
    }

    /// Whether the nearest caller outside this module (past the hook's own
    /// frames) is WebCore or WebKit, which reach the pasteboard through
    /// `WebCore::PlatformPasteboard`.
    private static func lookupComesFromWebKit() -> Bool {
        let addresses = Thread.callStackReturnAddresses
        guard let first = addresses.first, let own = imagePath(first) else { return false }
        for address in addresses.dropFirst().prefix(8) {
            guard let path = imagePath(address) else { return false }
            if path == own { continue }
            let image = (path as NSString).lastPathComponent
            return image == "WebCore" || image == "WebKit"
        }
        return false
    }

    private static func imagePath(_ address: NSNumber) -> String? {
        guard let pointer = UnsafeRawPointer(bitPattern: address.uintValue) else { return nil }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let name = info.dli_fname else { return nil }
        return String(cString: name)
    }

    @MainActor
    private static func finish(_ command: Command) {
        guard !command.finished.isSignaled else { return }
        endRedirect(to: command.pasteboard)
        if unfinished === command { unfinished = nil }
        if command.releasesPasteboardWhenFinished {
            command.pasteboard.clearContents()
            command.pasteboard.releaseGlobally()
        }
        command.finished.signal()
        command.whenFinished()
    }

    private static func setTarget(_ pasteboard: NSPasteboard?) {
        lock.lock()
        target = pasteboard
        lock.unlock()
    }

    private static func endRedirect(to pasteboard: NSPasteboard) {
        lock.lock()
        if target === pasteboard { target = nil }
        lock.unlock()
    }

    @MainActor
    private final class Command {
        let pasteboard: NSPasteboard
        let tab: String
        let whenFinished: @MainActor () -> Void
        let finished = BrowserReplLatch()
        /// Set when the caller handed the pasteboard over at a
        /// `timedOutStillRunning`.
        var releasesPasteboardWhenFinished = false

        init(pasteboard: NSPasteboard, tab: String, whenFinished: @escaping @MainActor () -> Void) {
            self.pasteboard = pasteboard
            self.tab = tab
            self.whenFinished = whenFinished
        }
    }
}

/// A one-shot signal that main-actor code can wait for with a deadline.
@MainActor
final class BrowserReplLatch {
    private(set) var isSignaled = false
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiter = 0

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(returning: true) }
    }

    /// Returns `true` once signaled, or `false` at `deadline` or, when
    /// `honoringCancellation`, as soon as the waiting task is cancelled.
    func wait<C: Clock>(
        until deadline: C.Instant,
        clock: C,
        honoringCancellation: Bool = true
    ) async -> Bool where C.Duration == Duration {
        if isSignaled { return true }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { @MainActor [weak self] in
            try? await clock.sleep(until: deadline, tolerance: nil)
            self?.resume(id, false)
        }
        defer { timer.cancel() }
        let register = { (continuation: CheckedContinuation<Bool, Never>) in
            if self.isSignaled || (honoringCancellation && Task.isCancelled) {
                continuation.resume(returning: self.isSignaled)
            } else {
                self.waiters[id] = continuation
            }
        }
        guard honoringCancellation else {
            return await withCheckedContinuation(register)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation(register)
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id, false) }
        }
    }

    private func resume(_ id: Int, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }
}

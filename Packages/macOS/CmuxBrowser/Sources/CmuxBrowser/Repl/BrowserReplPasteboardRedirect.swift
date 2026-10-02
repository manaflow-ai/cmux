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
///   done or until the timeout, whichever comes first. It never outlives the
///   timeout. A page that keeps the command running longer (a handler that
///   loops; dialogs from the tab are answered at once by the caller) reaches
///   the system pasteboard afterwards, and:
///   - its reads find nothing: WebKit grants a Paste's web process access to
///     the general pasteboard at the command's start, by the change count it
///     sees then, which is the tab pasteboard's, and refuses later reads
///     while the general pasteboard's change count differs. `perform` runs a
///     Paste only while the tab pasteboard's count is below the system's, so
///     the system's, which only grows, can never match it;
///   - its writes (a Copy or Cut the page finishes late) land on the system
///     clipboard.
/// - One command runs at a time, also after a timeout, until WebKit reports
///   it done, so an abandoned command's late writes never land in a later
///   command's pasteboard. A command that cannot start before its timeout
///   does not run, and nothing is redirected while it waits.
///
/// Residual risk: while a command is in flight (milliseconds, at most its
/// timeout), a person pasting or copying in another web view of this process
/// gets or fills the tab's pasteboard, and so does app code that WebKit
/// calls back into (a delegate) if it looks up the general pasteboard by
/// name. A copy made that way lands on the tab's clipboard. After a timeout,
/// a person's own paste in a web view that shares the abandoned page's web
/// process renews that process's access, so the page's late reads could
/// then see the person's clipboard. The caller test errs toward WebKit:
/// should WebKit's pasteboard code move, its lookups still come from a
/// WebKit image and stay redirected, unless it moves to
/// `+generalPasteboard`, which the WebKit tests catch as a change of the
/// system pasteboard's change count.
public enum BrowserReplPasteboardRedirect {
    /// How one command ended.
    public enum Outcome: Equatable, Sendable {
        /// WebKit reported the command done within the timeout; the tab's
        /// pasteboard holds what WebKit wrote during the command.
        case completed
        /// WebKit had not reported the command done within the timeout. The
        /// redirect has ended; the tab's pasteboard is no longer reachable
        /// and may be released at once.
        case timedOut
        /// An earlier command was still unfinished when the timeout passed;
        /// this one did not start.
        case busy
        /// The pasteboard lookup or WebKit's editing-command SPI is missing,
        /// or a Paste could not be kept from reading the system pasteboard
        /// late (see the type's documentation); the command did not start.
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

    /// Runs WebKit's `command` (`Copy`, `Cut` or `Paste`) in `webView` with
    /// `pasteboard` standing in for the general pasteboard.
    ///
    /// - Parameters:
    ///   - systemChangeCount: the system pasteboard's change count, read when
    ///     `nil`. A Paste runs only while `pasteboard`'s count is below it.
    ///   - whenWebKitFinishes: called once, when WebKit reports the command
    ///     done (also after a timeout), or at once when it did not start.
    @MainActor
    public static func perform(
        _ command: String,
        in webView: WKWebView,
        pasteboard: NSPasteboard,
        timeout: Duration = .seconds(5),
        systemChangeCount: Int? = nil,
        whenWebKitFinishes: @escaping @MainActor () -> Void = {}
    ) async -> Outcome {
        let selector = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webView.responds(to: selector),
              command != "Paste" || pasteboard.changeCount < (systemChangeCount ?? NSPasteboard.general.changeCount)
        else {
            whenWebKitFinishes()
            return .unavailable
        }
        return await run(on: pasteboard, timeout: timeout, whenFinished: whenWebKitFinishes) { done in
            typealias Completion = @convention(block) (Bool) -> Void
            typealias Function = @convention(c) (AnyObject, Selector, NSString, NSString?, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
            let completion: Completion = { _ in MainActor.assumeIsolated { done() } }
            function(webView, selector, command as NSString, "" as NSString, completion)
        }
    }

    /// Runs one command with `pasteboard` standing in for the general
    /// pasteboard for WebKit's lookups. `invoke` starts the command and calls
    /// its argument when WebKit reports the command done. The redirect lasts
    /// until then or until `timeout` on `clock`, whichever comes first;
    /// waiting for an earlier unfinished command counts toward the timeout.
    /// `whenFinished` is called once, when `invoke`'s argument is called or
    /// at once when the command does not start.
    @MainActor
    public static func run<C: Clock>(
        on pasteboard: NSPasteboard,
        timeout: Duration,
        clock: C = ContinuousClock(),
        whenFinished: @escaping @MainActor () -> Void = {},
        invoke: (_ done: @escaping @MainActor () -> Void) -> Void
    ) async -> Outcome where C.Duration == Duration {
        guard install() else {
            whenFinished()
            return .unavailable
        }
        let deadline = clock.now.advanced(by: timeout)
        while let earlier = unfinished {
            guard await earlier.finished.wait(until: deadline, clock: clock) else {
                whenFinished()
                return .busy
            }
        }
        let command = Command(pasteboard: pasteboard, whenFinished: whenFinished)
        unfinished = command
        setTarget(pasteboard)
        invoke { finish(command) }
        if await command.finished.wait(until: deadline, clock: clock) { return .completed }
        // Past the timeout, or the caller stopped waiting: the redirect ends
        // now, whatever WebKit still does.
        endRedirect(to: pasteboard)
        return .timedOut
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
        let whenFinished: @MainActor () -> Void
        let finished = BrowserReplLatch()

        init(pasteboard: NSPasteboard, whenFinished: @escaping @MainActor () -> Void) {
            self.pasteboard = pasteboard
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

    /// Returns `true` once signaled, or `false` at `deadline` or when the
    /// waiting task is cancelled.
    func wait<C: Clock>(until deadline: C.Instant, clock: C) async -> Bool where C.Duration == Duration {
        if isSignaled { return true }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { @MainActor [weak self] in
            try? await clock.sleep(until: deadline, tolerance: nil)
            self?.resume(id, false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if isSignaled || Task.isCancelled {
                    continuation.resume(returning: isSignaled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id, false) }
        }
    }

    private func resume(_ id: Int, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }
}

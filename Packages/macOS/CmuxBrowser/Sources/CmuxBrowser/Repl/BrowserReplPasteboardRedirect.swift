public import AppKit
import Darwin
import ObjectiveC
public import WebKit

/// Runs WebKit's own Copy, Cut and Paste editing commands against a REPL
/// tab's private pasteboard instead of the system clipboard.
///
/// WebKit starts an editing command in the UI process and returns; the web
/// process then reads or writes the pasteboard through IPC messages that the
/// UI process answers later on the main thread, each through WebCore's
/// `PlatformPasteboard`, which looks the general pasteboard up by name
/// (`+[NSPasteboard pasteboardWithName:]`). A window around the synchronous
/// call alone would miss every read and write, so the redirect is narrowed
/// by caller instead of by time:
///
/// - Only a lookup of the general pasteboard's name made by WebKit's own code
///   (the nearest caller outside this module is WebCore or WebKit) gets the
///   tab's pasteboard. `NSPasteboard.general` and lookups by any other code,
///   such as the terminal, always get the system pasteboard.
/// - The redirect lasts from the start of the command until WebKit reports
///   it done, even when the caller stopped waiting earlier, so a late paste
///   reads the tab's pasteboard and a late copy writes it; neither falls
///   back to the user's clipboard. WebKit always calls an editing command's
///   completion, also when the web process exits.
/// - One command runs at a time. A command that cannot start before its
///   timeout because an earlier one is unfinished does not run.
///
/// Residual risk: while a REPL command is in flight (milliseconds), a person
/// pasting into another web view of this process gets the tab's clipboard,
/// and so does app code that WebKit calls back into (a delegate) if it looks
/// up the general pasteboard by name. The caller test errs toward WebKit:
/// should WebKit's pasteboard code move, its lookups still come from a
/// WebKit image and stay redirected, never reaching the user's clipboard.
public enum BrowserReplPasteboardRedirect {
    /// How one command ended.
    public enum Outcome: Equatable, Sendable {
        /// WebKit reported the command done.
        case completed
        /// WebKit had not reported the command done within the timeout. The
        /// redirect stays until it does and then releases the pasteboard
        /// (`releaseGlobally()`); the caller must not release it.
        case timedOut
        /// An earlier command was still unfinished when the timeout passed;
        /// this one did not start.
        case busy
        /// The pasteboard lookup or WebKit's editing-command SPI is missing.
        case unavailable
    }

    nonisolated(unsafe) private static var target: NSPasteboard?
    private static let lock = NSLock()
    @MainActor private static var installed = false
    @MainActor private static var active: Window?

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
    @MainActor
    public static func perform(
        _ command: String,
        in webView: WKWebView,
        pasteboard: NSPasteboard,
        timeout: Duration = .seconds(5)
    ) async -> Outcome {
        let selector = NSSelectorFromString("_executeEditCommand:argument:completion:")
        guard webView.responds(to: selector) else { return .unavailable }
        return await run(on: pasteboard, timeout: timeout) { done in
            typealias Completion = @convention(block) (Bool) -> Void
            typealias Function = @convention(c) (AnyObject, Selector, NSString, NSString?, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
            let completion: Completion = { _ in MainActor.assumeIsolated { done() } }
            function(webView, selector, command as NSString, "" as NSString, completion)
        }
    }

    /// Runs one command with `pasteboard` standing in for the general
    /// pasteboard for WebKit's lookups. `invoke` starts the command and calls
    /// its argument when WebKit reports the command done; the redirect lasts
    /// until then. Waiting, for an earlier command and for this one, ends at
    /// `timeout` on `clock`.
    @MainActor
    public static func run<C: Clock>(
        on pasteboard: NSPasteboard,
        timeout: Duration,
        clock: C = ContinuousClock(),
        invoke: (_ done: @escaping @MainActor () -> Void) -> Void
    ) async -> Outcome where C.Duration == Duration {
        guard install() else { return .unavailable }
        let deadline = clock.now.advanced(by: timeout)
        while let earlier = active {
            guard await earlier.finished.wait(until: deadline, clock: clock) else { return .busy }
        }
        let window = Window(pasteboard: pasteboard)
        active = window
        setTarget(pasteboard)
        invoke { close(window) }
        guard await window.finished.wait(until: deadline, clock: clock) else {
            window.abandoned = true
            return .timedOut
        }
        return .completed
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
    private static func close(_ window: Window) {
        guard !window.finished.isSignaled else { return }
        if active === window {
            active = nil
            setTarget(nil)
        }
        window.finished.signal()
        if window.abandoned { window.pasteboard.releaseGlobally() }
    }

    private static func setTarget(_ pasteboard: NSPasteboard?) {
        lock.lock()
        target = pasteboard
        lock.unlock()
    }

    @MainActor
    private final class Window {
        let pasteboard: NSPasteboard
        let finished = BrowserReplLatch()
        var abandoned = false

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
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

public import AppKit
import Darwin
import ObjectiveC

/// Keeps an automated HTML5 drag's data off the system's named drag
/// pasteboard, which every process of the user can read and overwrite.
///
/// WebKit has no per-web-view pasteboard: when a drag starts it writes the
/// drag's data to the pasteboard it looks up by the drag pasteboard's name
/// (`+[NSPasteboard pasteboardWithName:]`), on the main thread, and that
/// lookup does not say which web view it serves. So while an automated
/// drag's window is open (``openDragWindow(_:timeout:clock:)``, around the
/// mouse moves that may start the drag), WebKit's lookups of the drag
/// pasteboard's name made on WebKit's own run-loop turn get the drag's own
/// private pasteboard. Lookups by other code (AppKit, cmux, the terminal)
/// always get the system's. A lookup by WebKit called by the app during the
/// window (a person's drop in another web view, which grants that web
/// view's process read access) diverts the window: from then until it
/// closes, every lookup gets an extra private pasteboard that is emptied at
/// each lookup, so the person's drop reads nothing and the automated drag
/// carries no data.
///
/// This hook covers only the drag pasteboard's name. The general pasteboard
/// (the clipboard) is never redirected: a tab a REPL session created has a
/// virtual clipboard that never touches a pasteboard
/// (``BrowserReplFrameGate/runClipboardShortcut(_:clipboard:in:frames:)``,
/// ``BrowserReplPageClipboard``).
public final class BrowserReplDragPasteboardRedirect: @unchecked Sendable {
    /// The redirect: one per process, since the hook it installs is.
    public static let shared = BrowserReplDragPasteboardRedirect()

    private init() {}

    private var targets: [String: Target] = [:]
    private let lock = NSLock()
    @MainActor private var installed = false
    /// The automated drag whose window is open.
    @MainActor private var dragWindow: DragWindow?

    /// Installs the process-wide `+[NSPasteboard pasteboardWithName:]` hook
    /// once. Returns `false` when the method is missing.
    @MainActor
    public func install() -> Bool {
        if installed { return true }
        let selector = NSSelectorFromString("pasteboardWithName:")
        guard let method = class_getClassMethod(NSPasteboard.self, selector) else { return false }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSPasteboard
        let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        let replacement: @convention(block) @Sendable (AnyObject, NSString) -> NSPasteboard = { cls, name in
            self.redirectedLookup(of: name as String) ?? original(cls, selector, name)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        installed = true
        return true
    }

    /// Who made a lookup of a pasteboard by name.
    public enum LookupOrigin: Equatable, Sendable {
        /// Code outside WebKit: the terminal, AppKit, cmux.
        case notWebKit
        /// WebKit on a run-loop turn of its own: handling a message from a
        /// web content process (its pasteboard reads and writes), or its own
        /// timer.
        case webKitOnItsOwnTurn
        /// WebKit called by the app: AppKit or cmux code that started an
        /// action in a web view (a person's drop), or a web content process's
        /// message WebKit handled while such a call waited.
        case webKitCalledByTheApp
    }

    /// The pasteboard a lookup of the pasteboard named `name` gets instead
    /// of the system's, or `nil` for the system's: the drag's pasteboard for
    /// a lookup by WebKit on its own turn while a drag window is open. A
    /// lookup by WebKit called by the app diverts the window (see the type's
    /// documentation).
    public func redirectTarget(forLookupOf name: String, origin: LookupOrigin) -> NSPasteboard? {
        guard origin != .notWebKit else { return nil }
        lock.lock()
        guard let target = targets[name] else {
            lock.unlock()
            return nil
        }
        if let sink = target.sink {
            lock.unlock()
            sink.clearContents()
            return sink
        }
        if origin == .webKitOnItsOwnTurn {
            lock.unlock()
            return target.pasteboard
        }
        lock.unlock()
        return divert(target)
    }

    /// What WebKit's lookup of the pasteboard named `name` gets: on its own
    /// turn when `fromWebKit`, else as code outside WebKit.
    public func redirectTarget(forLookupOf name: String, fromWebKit: Bool) -> NSPasteboard? {
        redirectTarget(forLookupOf: name, origin: fromWebKit ? .webKitOnItsOwnTurn : .notWebKit)
    }

    /// Gives `target` its private sink (once) and returns it, emptied.
    private func divert(_ target: Target) -> NSPasteboard {
        // Created outside the lock: making a pasteboard may look one up by
        // name, which comes back through the hook.
        let fresh = NSPasteboard.withUniqueName()
        lock.lock()
        let sink: NSPasteboard
        if let existing = target.sink {
            sink = existing
        } else {
            target.sink = fresh
            sink = fresh
        }
        lock.unlock()
        if sink !== fresh { fresh.releaseGlobally() }
        sink.clearContents()
        return sink
    }

    private func redirectedLookup(of name: String) -> NSPasteboard? {
        lock.lock()
        let inFlight = targets[name] != nil
        lock.unlock()
        guard inFlight else { return nil }
        return redirectTarget(forLookupOf: name, origin: Self.lookupOrigin())
    }

    /// Classifies the caller of the hook running on this thread.
    private static func lookupOrigin() -> LookupOrigin {
        let addresses = Thread.callStackReturnAddresses
        guard let first = addresses.first, let own = imagePath(first) else { return .notWebKit }
        var callers: [String] = []
        for address in addresses.dropFirst() {
            guard let path = imagePath(address) else { break }
            if callers.isEmpty, path == own { continue }
            let image = (path as NSString).lastPathComponent
            callers.append(image)
            if !webKitImages.contains(image) { break }
        }
        return origin(ofCallerImages: callers)
    }

    private static let webKitImages: Set<String> = [
        "WebKit", "WebCore", "JavaScriptCore", "WebKitLegacy", "WebGPU", "libwebrtc.dylib", "libANGLE-shared.dylib",
    ]

    /// The origin of a lookup whose callers, nearest first and past the
    /// hook's own frames, are in the images named `images`. WebCore or
    /// WebKit must come first. Past WebKit's frames (WTF lives in
    /// JavaScriptCore), the run loop (CoreFoundation or libdispatch) means
    /// WebKit runs on its own turn; anything else, or the stack's end, means
    /// the app called WebKit.
    static func origin(ofCallerImages images: [String]) -> LookupOrigin {
        guard let first = images.first, first == "WebCore" || first == "WebKit" else { return .notWebKit }
        for image in images.dropFirst() where !webKitImages.contains(image) {
            return image == "CoreFoundation" || image == "libdispatch.dylib" ? .webKitOnItsOwnTurn : .webKitCalledByTheApp
        }
        return .webKitCalledByTheApp
    }

    private static func imagePath(_ address: NSNumber) -> String? {
        guard let pointer = UnsafeRawPointer(bitPattern: address.uintValue) else { return nil }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let name = info.dli_fname else { return nil }
        return String(cString: name)
    }

    @discardableResult
    private func setTarget(_ pasteboard: NSPasteboard, for name: NSPasteboard.Name) -> Target {
        let target = Target(pasteboard: pasteboard)
        lock.lock()
        targets[name.rawValue] = target
        lock.unlock()
        return target
    }

    private func endRedirect(to pasteboard: NSPasteboard, for name: NSPasteboard.Name) {
        lock.lock()
        var sink: NSPasteboard?
        if let target = targets[name.rawValue], target.pasteboard === pasteboard {
            targets[name.rawValue] = nil
            sink = target.sink
        }
        lock.unlock()
        sink?.clearContents()
        sink?.releaseGlobally()
    }

    /// One name's redirect. Fields are guarded by the redirect's `lock`.
    private final class Target: @unchecked Sendable {
        let pasteboard: NSPasteboard
        /// The private pasteboard every lookup gets once the window was
        /// diverted.
        var sink: NSPasteboard?

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }
    }

    // MARK: - Automated drags

    /// Opens `pasteboard`'s drag window: until ``closeDragWindow(_:)`` or
    /// `timeout`, WebKit's lookups of the drag pasteboard by name (the
    /// pasteboard an HTML5 drag's data is written to when the drag starts)
    /// get `pasteboard`, never the system's named drag pasteboard, which
    /// every process of the user can read and overwrite. Lookups by other
    /// code keep the system's.
    ///
    /// One window is open at a time in the whole app, since WebKit's
    /// lookups do not say which web view a drag starts in: an open window of
    /// another drag is waited for, up to `timeout`, and `false` means it was
    /// still open then and this one did not open. Opening the window that is
    /// already open returns `true`.
    @MainActor
    public func openDragWindow<C: Clock>(
        _ pasteboard: NSPasteboard,
        timeout: Duration = .seconds(5),
        clock: C = ContinuousClock()
    ) async -> Bool where C.Duration == Duration {
        guard install() else { return false }
        let deadline = clock.now.advanced(by: timeout)
        while let open = dragWindow {
            if open.pasteboard === pasteboard { return true }
            guard await open.closed.wait(until: deadline, clock: clock, honoringCancellation: false) else { return false }
        }
        let window = DragWindow(pasteboard: pasteboard)
        dragWindow = window
        setTarget(pasteboard, for: .drag)
        // Bounded: a drag the page never starts does not keep every other
        // web view's drag data on this pasteboard.
        let bound = clock.now.advanced(by: timeout)
        Task { @MainActor in
            if await window.closed.wait(until: bound, clock: clock, honoringCancellation: false) { return }
            self.closeDragWindow(pasteboard)
        }
        return true
    }

    /// Closes `pasteboard`'s drag window, if it is the open one.
    @MainActor
    public func closeDragWindow(_ pasteboard: NSPasteboard) {
        guard let window = dragWindow, window.pasteboard === pasteboard else { return }
        endRedirect(to: pasteboard, for: .drag)
        dragWindow = nil
        window.closed.signal()
    }

    @MainActor
    private final class DragWindow {
        let pasteboard: NSPasteboard
        let closed = BrowserReplLatch()

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

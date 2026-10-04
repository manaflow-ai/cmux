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
///   `+[NSPasteboard generalPasteboard]` is never redirected; WebKit's Copy,
///   Cut and Paste do not use it.
/// - Of WebKit's lookups, only those it makes on its own run-loop turn (the
///   nearest caller past WebKit's frames is the run loop: WebKit handling a
///   web content process's pasteboard message) and those it makes while it
///   starts the command get the tab's pasteboard. WebKit's lookups do not
///   say which web view or process they serve, but a web content process
///   reads the general pasteboard only after the app grants it access, at
///   the change count the lookup returns then (`WebPasteboardProxy`); a
///   person's Command-V, Edit menu or context menu Paste or paste callout in
///   another web view starts that grant from a call by the app (AppKit or
///   cmux code) into WebKit. Such a lookup during a command, or WebKit's read
///   of `+generalPasteboard` (its check before it grants a page's clipboard
///   read without asking, which can come on its own turn), diverts the
///   command: that lookup and every later one until the command ends get a
///   private pasteboard emptied at each lookup. The tab's pasteboard is then
///   handed out no more, a grant made on the private one matches no later
///   change count, and nothing written there can be read back; the command
///   is `interfered`.
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
/// - A copy another web view makes during the command (its writes are
///   messages WebKit handles on its own turn, so they get the tab's
///   pasteboard too) is never taken as the tab's: WebKit's own Copy or Cut
///   writes the pasteboard at most once and a Paste never does (each write
///   is one change count), so a command whose pasteboard was written more
///   often is `interfered`, and the caller discards the pasteboard.
///
/// Residual risk: while a command is in flight (milliseconds, at most its
/// timeout), a copy made in another web view of this process lands on the
/// tab's pasteboard (and does not reach the system clipboard); it reaches the
/// tab's clipboard only when it is the one write of a Copy or Cut whose page
/// wrote nothing itself (a `copy` handler that cancels the event and sets no
/// data). A web content process the app granted read access on its own turn
/// without a `+generalPasteboard` read first would read the tab's pasteboard;
/// WebKit 26 has no such grant. A paste in another web view that starts
/// during the command reads nothing. The same holds after a
/// `timedOutStillRunning` until WebKit finishes, at most one more timeout.
/// The caller test errs toward WebKit: should WebKit's pasteboard code move,
/// its lookups still come from a WebKit image and stay redirected (its own
/// turn) or divert the command (a call from the app), unless it moves to
/// `+generalPasteboard`, which the WebKit tests catch as a change of the
/// system pasteboard's change count. Writes a page's own scripts make (the
/// asynchronous Clipboard API, `execCommand("copy")`) are not commands and
/// are not redirected; ``BrowserReplPageClipboard`` handles those.
public final class BrowserReplPasteboardRedirect: @unchecked Sendable {
    /// The redirect: one per process, since the hook it installs is.
    public static let shared = BrowserReplPasteboardRedirect()

    private init() {}

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
        /// WebKit reported the command done within the timeout, but another
        /// web view used the pasteboard during the command: the tab's
        /// pasteboard was written more often than the command writes it
        /// (WebKit's Copy or Cut writes it at most once, a Paste never), or
        /// another web view's paste or clipboard read diverted the command
        /// (the page may have pasted nothing). What the pasteboard holds is
        /// not the tab's, and the caller must not take it.
        case interfered
        /// The pasteboard lookup or WebKit's editing-command or
        /// process-ending SPI is missing, the caller may not end the web
        /// content process, or a Paste could not be kept from reading the
        /// system pasteboard late (see the type's documentation); the
        /// command did not start.
        case unavailable
    }

    /// What WebKit's lookups of each name get instead of the system's
    /// pasteboard: the general pasteboard's during a command, the drag
    /// pasteboard's during an automated drag's window. Guarded by `lock`;
    /// read by the hooks on any thread.
    private var targets: [String: Target] = [:]
    private let lock = NSLock()
    @MainActor private var installed = false
    /// The command WebKit has not reported done, within or past its timeout.
    @MainActor private var unfinished: Command?
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
        // `+generalPasteboard` is not redirected; a call from WebKit during
        // a command only marks the command (see `noteSystemPasteboardRead`).
        let generalSelector = NSSelectorFromString("generalPasteboard")
        if let generalMethod = class_getClassMethod(NSPasteboard.self, generalSelector) {
            typealias General = @convention(c) (AnyObject, Selector) -> NSPasteboard
            let originalGeneral = unsafeBitCast(method_getImplementation(generalMethod), to: General.self)
            let generalReplacement: @convention(block) @Sendable (AnyObject) -> NSPasteboard = { cls in
                self.noteSystemPasteboardRead()
                return originalGeneral(cls, generalSelector)
            }
            method_setImplementation(generalMethod, imp_implementationWithBlock(generalReplacement))
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
    public func perform(
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
        guard webView.responds(to: Self.editCommandSelector),
              webView.responds(to: Self.endWebContentSelector),
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
            maximumWrites: command == "Paste" ? 0 : 1,
            endWebContent: {
                // At the timeout the caller decides; one timeout later the
                // web content is ended regardless.
                askedToEnd += 1
                guard askedToEnd > 1 || mayEndWebContent() else { return false }
                return self.endWebContent(of: webView)
            },
            whenFinished: whenWebKitFinishes
        ) { done in
            typealias Completion = @convention(block) (Bool) -> Void
            typealias Function = @convention(c) (AnyObject, Selector, NSString, NSString?, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: Self.editCommandSelector), to: Function.self)
            let completion: Completion = { _ in MainActor.assumeIsolated { done() } }
            function(webView, Self.editCommandSelector, command as NSString, "" as NSString, completion)
        }
    }

    /// Ends `webView`'s web content process at once (WebKit's
    /// `_killWebContentProcessAndResetState`): WebKit stops handling that
    /// process's messages before this returns and reports the termination to
    /// the navigation delegate. Returns `false` when the SPI is missing.
    @MainActor
    public func endWebContent(of webView: WKWebView) -> Bool {
        guard webView.responds(to: Self.endWebContentSelector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(webView.method(for: Self.endWebContentSelector), to: Function.self)
        function(webView, Self.endWebContentSelector)
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
    /// regardless) and the redirect ends whatever it returns. A command that
    /// completed but whose pasteboard was written more than `maximumWrites`
    /// times during it is `interfered`. Cancelling the caller's task
    /// shortens none of these waits. `whenFinished` is called once, when
    /// `invoke`'s argument is called or the web content is ended, or at once
    /// when the command does not start.
    @MainActor
    public func run<C: Clock>(
        on pasteboard: NSPasteboard,
        tab: String = "",
        timeout: Duration,
        grace: Duration? = nil,
        maximumWrites: Int? = nil,
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
        let startCount = pasteboard.changeCount
        let target = setTarget(pasteboard)
        let deadline = clock.now.advanced(by: timeout)
        // WebKit's lookups while it starts the command, inside this call,
        // are the command's own (a Paste's access grant).
        setStarting(target, true)
        invoke { self.finish(command) }
        setStarting(target, false)
        // The redirect ended when WebKit reported the command done, so no
        // write reaches the pasteboard after that.
        let completed: () -> Outcome = {
            if self.isDiverted(target) { return .interfered }
            guard let maximumWrites, pasteboard.changeCount - startCount > maximumWrites else { return .completed }
            return .interfered
        }
        if await command.finished.wait(until: deadline, clock: clock, honoringCancellation: false) { return completed() }
        // Past the timeout. Until this turn ends nothing else runs on the
        // main thread, so WebKit handles no more of the page's pasteboard
        // messages before its process is gone.
        if command.finished.isSignaled { return completed() }
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

    /// Who made a lookup of a pasteboard by name.
    public enum LookupOrigin: Equatable, Sendable {
        /// Code outside WebKit: the terminal, AppKit, cmux.
        case notWebKit
        /// WebKit on a run-loop turn of its own: handling a message from a
        /// web content process (its pasteboard reads and writes), or its own
        /// timer.
        case webKitOnItsOwnTurn
        /// WebKit called by the app: AppKit or cmux code that started an
        /// action in a web view (a person's Command-V, the Edit menu's or a
        /// context menu's Paste, a paste-permission callout, a drop), or a
        /// web content process's message WebKit handled while such a call
        /// waited.
        case webKitCalledByTheApp
    }

    /// The pasteboard a lookup of the pasteboard named `name` gets instead
    /// of the system's, or `nil` for the system's: the tab's pasteboard for
    /// a lookup by WebKit on its own turn while a command is in flight (and
    /// for WebKit's lookups while it starts the command).
    ///
    /// A lookup by WebKit called by the app during a command is another
    /// web view's action: WebKit's lookup to grant a web content process
    /// read access, at the change count it sees then, comes this way. It
    /// diverts the command: that lookup and every later one of the name
    /// until the command ends get a private pasteboard that is emptied at
    /// every lookup, so the tab's pasteboard is never handed out again, a
    /// grant made on it matches no later change count, and nothing written
    /// to it can be read back. The command ends `interfered`.
    public func redirectTarget(
        forLookupOf name: String,
        origin: LookupOrigin,
        onMainThread: Bool = Thread.isMainThread
    ) -> NSPasteboard? {
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
        if origin == .webKitOnItsOwnTurn || (onMainThread && target.starting) {
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

    /// Records a read of `+[NSPasteboard generalPasteboard]` with `origin`.
    /// WebKit reads it there only to answer a web page's clipboard read
    /// (whether the system clipboard holds the page's own origin's data,
    /// before it grants that page's process read access without asking),
    /// never for a command; during a command such a read diverts it (see
    /// ``redirectTarget(forLookupOf:origin:onMainThread:)``), since the grant
    /// that follows can come on WebKit's own turn.
    public func noteSystemPasteboardRead(origin: LookupOrigin) {
        guard origin != .notWebKit else { return }
        lock.lock()
        let target = targets[NSPasteboard.Name.general.rawValue]
        lock.unlock()
        if let target { _ = divert(target) }
    }

    private func noteSystemPasteboardRead() {
        lock.lock()
        let inFlight = targets[NSPasteboard.Name.general.rawValue] != nil
        lock.unlock()
        guard inFlight else { return }
        noteSystemPasteboardRead(origin: Self.lookupOrigin())
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

    @MainActor
    private func finish(_ command: Command) {
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

    @discardableResult
    private func setTarget(_ pasteboard: NSPasteboard, for name: NSPasteboard.Name = .general) -> Target {
        let target = Target(pasteboard: pasteboard)
        lock.lock()
        targets[name.rawValue] = target
        lock.unlock()
        return target
    }

    private func setStarting(_ target: Target, _ starting: Bool) {
        lock.lock()
        target.starting = starting
        lock.unlock()
    }

    /// Whether `target` was diverted (see ``redirectTarget(forLookupOf:origin:onMainThread:)``).
    private func isDiverted(_ target: Target) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return target.sink != nil
    }

    private func endRedirect(to pasteboard: NSPasteboard, for name: NSPasteboard.Name = .general) {
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
        /// Set on the main thread while WebKit starts the command.
        var starting = false
        /// The private pasteboard every lookup gets once the redirect was
        /// diverted.
        var sink: NSPasteboard?

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }
    }

    // MARK: - Agent gestures

    /// Starts a quarantine of WebKit's writes of the general pasteboard.
    @MainActor
    public func beginQuarantine() -> Bool {
        install()
    }

    /// Ends one ``beginQuarantine()``.
    @MainActor
    public func endQuarantine(lingering: Duration) {}

    /// Ends every quarantine at once (tests).
    @MainActor
    func liftQuarantine() {}

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

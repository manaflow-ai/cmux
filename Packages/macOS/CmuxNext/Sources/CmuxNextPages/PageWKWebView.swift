import AppKit
import Foundation
import ObjectiveC
import WebKit

/// The WebKit view of every first-party page (DESKTOP-FEEL, R139): the host half of the shared
/// desktop layer (the web half is webviews/src/pages/shared/desktop.ts). A page is app chrome:
/// - no pinch or smart magnification (the UI scale comes from the app);
/// - the native context menu offers only Copy, and only on a selection (a page that draws its own
///   menu cancels `contextmenu`, so WebKit shows none);
/// - Select All acts only inside the focused field, never over the whole page.
/// Swipe navigation and link previews are off in ``PageWebView``. Third-party pages in browser tabs
/// use their own views and are not affected.
@MainActor
// webview-allow: the page host's WebKit engine; PageEnginePolicy picks it
final class PageWKWebView: WKWebView {
    var onUserEvent: (() -> Void)?
    /// Whether the page now shown accepts the first mouse (``PageDescriptor/acceptsFirstMouse``);
    /// read per click, so a pooled view rebound to another page answers for that page.
    var pageAcceptsFirstMouse: (() -> Bool)?
    /// The context menu items a page keeps: Copy (WebKit adds it only when there is a selection).
    static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy"]

    /// Selects the text of the focused field; does nothing when no field has focus.
    static let selectAllScript = """
    (() => {
      const el = document.activeElement;
      if (!el) return false;
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { el.select(); return true; }
      if (el.isContentEditable) { document.execCommand('selectAll'); return true; }
      return false;
    })()
    """

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsMagnification = false
        // A choice in this view's context menu is the person's input (``menuWillSendAction(_:)``).
        // queue: .main runs the block inline for AppKit's post on main, before the action is
        // sent; a selector into this main-actor view trapped on a post off main.
        menuActionObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.willSendActionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The menu's identity crosses into the main-actor block (an NSMenu is not Sendable).
            let sender = (note.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.menuWillSendAction(from: sender) } // main-proof: observer on queue: .main
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var menuActionObserver: (any NSObjectProtocol)?

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let menuActionObserver { NotificationCenter.default.removeObserver(menuActionObserver) }
        }
    }

    /// When a real key or mouse event last reached this view (`systemUptime`): a page call shortly
    /// after it is backed by the person's gesture (``hasRecentUserGesture(within:)``). Page script
    /// cannot set it.
    private(set) var lastUserEventUptime: TimeInterval?

    /// Whether a key or mouse event reached the view within `seconds`.
    func hasRecentUserGesture(within seconds: TimeInterval = 1, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        recentUserGestureEvent(within: seconds, now: now) != nil
    }

    /// The uptime of the key or mouse event that reached the view within `seconds`, else nil.
    func recentUserGestureEvent(within seconds: TimeInterval = 1, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard let last = lastUserEventUptime, now - last <= seconds else { return nil }
        return last
    }

    func noteUserEvent(_ event: NSEvent) {
        noteUserActivation(at: event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime)
    }

    /// Drops the recorded activation and the opened menu: the view now shows another document
    /// (a pooled view rebound or parked), which must not use a gesture made in the old one.
    func forgetUserActivation() {
        lastUserEventUptime = nil
        openedMenu = nil
    }

    private func noteUserActivation(at uptime: TimeInterval) {
        onUserEvent?()
        lastUserEventUptime = uptime
    }

    /// The context menu WebKit last opened over this view (weak: AppKit owns it).
    private weak var openedMenu: NSMenu?

    /// An item of this view's context menu (or one of its submenus) is about to send its action:
    /// the person chose it, so the page call it leads to (a host-built Copy) follows a gesture.
    /// AppKit posts this only for a real menu choice; page script cannot.
    private func menuWillSendAction(from sender: ObjectIdentifier?) {
        guard let opened = openedMenu, let sender, Self.menu(opened, contains: sender) else { return }
        noteUserActivation(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Whether `id` is `menu` or one of its submenus (at any depth).
    private static func menu(_ menu: NSMenu, contains id: ObjectIdentifier) -> Bool {
        ObjectIdentifier(menu) == id || menu.items.contains { item in item.submenu.map { Self.menu($0, contains: id) } ?? false }
    }

    /// On a page that opts in (``PageDescriptor/acceptsFirstMouse``, off by default), a first click
    /// in an inactive window reaches the page, as on the native controls (sidebar rows, dividers,
    /// toasts, popup rows): WebKit accepts a first mouse only to drag a selection, so a person's
    /// click on a page button only activated the window. Every other page, and a view with no
    /// owner, keeps WebKit's answer.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if pageAcceptsFirstMouse?() ?? false { return true }
        // WebKit reads the event (its location); without one it has no first mouse to accept.
        guard let event else { return false }
        return super.acceptsFirstMouse(for: event)
    }

    /// Called each time this view becomes first responder (pane focus, a click, a restore); the
    /// owning ``PageWebView`` tells the page (`focusContent`), which focuses its primary input.
    var onBecameFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecameFirstResponder?() }
        return became
    }

    override func keyDown(with event: NSEvent) { noteUserEvent(event); super.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { noteUserEvent(event); super.keyUp(with: event) }
    override func mouseDown(with event: NSEvent) { noteUserEvent(event); menuAutoFill.noteContextClick(event); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { noteUserEvent(event); super.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { noteUserEvent(event); super.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { noteUserEvent(event); menuAutoFill.noteContextClick(event); super.rightMouseDown(with: event) }

    /// Replaces the Copy-only menu when set (``PageWebView/contextMenuEditor``).
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)?

    /// Keeps macOS's AutoFill out of this view's context menu (``PageMenuAutoFill``).
    private let menuAutoFill = PageMenuAutoFill()

    override var inputContext: NSTextInputContext? {
        menuAutoFill.hidesInputContext() ? nil : super.inputContext
    }

    /// No caret accessory on a cmux page. Since macOS 14 the system draws a small glass bubble
    /// beside the caret of the focused field (the input source, Caps Lock, dictation); in the
    /// composer the caret of an empty prompt sits just above the + button, which the bubble covered
    /// (Leo, 2026-10-21). AppKit asks the focused `NSTextInputClient` (this view) for its placement
    /// and draws nothing for `.invisible`. Browser tabs use their own views and keep the bubble;
    /// Chromium's view of a cmux page answers the same (`ChromiumPageTextAccessory`).
    @objc var preferredTextAccessoryPlacement: NSTextCursorAccessoryPlacement { .invisible }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        openedMenu = menu
        menuAutoFill.menuWillOpen()
        if let contextMenuEditor { contextMenuEditor(menu) } else { Self.keepDesktopItems(in: menu) }
        super.willOpenMenu(menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        menuAutoFill.menuDidClose()
        super.didCloseMenu(menu, with: event)
    }

    /// Removes every item but Copy (and the separators around removed items).
    static func keepDesktopItems(in menu: NSMenu) {
        for item in menu.items.reversed() where !keptMenuItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
    }

    override func selectAll(_ sender: Any?) {
        evaluateJavaScript(Self.selectAllScript, completionHandler: nil)
    }

    override func magnify(with event: NSEvent) {}

    override func smartMagnify(with event: NSEvent) {}

    // MARK: Host file drops (diff-host S4)

    /// File drops the host opens itself (``PageFileDrop``, the diff viewer's empty state); nil gives
    /// every drag to WebKit.
    var fileDrop: PageFileDrop?

    /// Reads the first file URL of a drag's pasteboard: a round trip to the pasteboard server.
    var readDroppedFileURL: @MainActor (NSPasteboard) -> URL? = { pasteboard in
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }

    /// Reads every file URL of a drop's pasteboard, once, as the page takes the drop.
    var readDroppedFileURLs: @MainActor (NSPasteboard) -> [URL] = { pasteboard in
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// The answer for the current drag: its pasteboard does not change during the drag, and AppKit
    /// waits for every `draggingUpdated`, so the file is read once per drag, not on every move.
    private var dragAnswer: (sequence: Int, url: URL?)?

    private func droppedFile(_ info: any NSDraggingInfo) -> URL? {
        guard let fileDrop else { return nil }
        if let answer = dragAnswer, answer.sequence == info.draggingSequenceNumber { return answer.url }
        let url = readDroppedFileURL(info.draggingPasteboard).flatMap { fileDrop.accepts($0) ? $0 : nil }
        dragAnswer = (info.draggingSequenceNumber, url)
        return url
    }

    /// The `NSDraggingDestination` methods WebKit implements. They are optional and NSView has no
    /// default for every one (no WKWebView has `draggingEnded:`), so `super` for a missing one throws
    /// "unrecognized selector" and ends the app. Each override calls `super` only when WebKit has it.
    private enum WebKitDrag {
        static let entered = WKWebView.instancesRespond(to: #selector(NSDraggingDestination.draggingEntered(_:)))
        static let updated = WKWebView.instancesRespond(to: #selector(NSDraggingDestination.draggingUpdated(_:)))
        static let exited = WKWebView.instancesRespond(to: #selector(NSDraggingDestination.draggingExited(_:)))
        static let ended = WKWebView.instancesRespond(to: #selector(NSDraggingDestination.draggingEnded(_:)))
        static let perform = WKWebView.instancesRespond(to: #selector(NSDraggingDestination.performDragOperation(_:)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragAnswer = nil
        if droppedFile(sender) != nil { return .copy }
        return WebKitDrag.entered ? super.draggingEntered(sender) : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragAnswer = nil
        if WebKitDrag.exited { super.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragAnswer = nil
        if WebKitDrag.ended { super.draggingEnded(sender) }
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if droppedFile(sender) != nil { return .copy }
        return WebKitDrag.updated ? super.draggingUpdated(sender) : []
    }

    /// Files dropped on the page itself (not a ``fileDrop`` the host opens), with their URLs: a real
    /// gesture page script can't make. It runs before WebKit hands the files to the page.
    var onFilesDropped: (@MainActor ([URL]) -> Void)?

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let url = droppedFile(sender)
        dragAnswer = nil
        guard let url, let fileDrop else {
            if let onFilesDropped {
                let urls = readDroppedFileURLs(sender.draggingPasteboard)
                if !urls.isEmpty { onFilesDropped(urls) }
            }
            return WebKitDrag.perform ? super.performDragOperation(sender) : false
        }
        fileDrop.open(url)
        return true
    }

    // MARK: Paste

    /// A paste (Cmd-V, Edit > Paste, a page's own Paste item) is about to reach the page; WebKit
    /// pastes right after.
    var onPaste: (@MainActor () -> Void)?

    @objc func paste(_ sender: Any?) {
        onPaste?()
        webKitPaste(sender)
    }

    // MARK: Page suspend (p13-webui-029 spike)

    /// WebKit's page suspend SPI (`WKWebViewPrivate.h`), found once per process; nil when this WebKit
    /// lacks a part of it. Not used by the page lifecycle yet: ``PageWebKitParking`` picks it only
    /// from a live measurement.
    static let pageSuspendSPI = PageSuspendSPI(in: WKWebView.self)

    /// Whether WebKit holds this page suspended; false when this WebKit has no suspend SPI.
    var isPageSuspended: Bool { Self.pageSuspendSPI?.isSuspended(self) ?? false }

    /// Suspends the hidden page (`WebPageProxy::suspend`, the suspension a back-forward page gets): it
    /// runs no script, timer or animation and keeps its document. WebKit raises on a public call
    /// (`evaluateJavaScript`, a load) to a suspended view, so the owner resumes it before any call.
    /// `done` gets the web process's answer.
    ///
    /// - Returns: Whether the page is suspended now (WebKit sets its flag in this call); false with no
    ///   call into WebKit when this WebKit has no suspend SPI or the page is already suspended.
    @discardableResult
    func suspendPage(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard let spi = Self.pageSuspendSPI, !spi.isSuspended(self) else { return false }
        spi.send(spi.suspend, to: self, done)
        return spi.isSuspended(self)
    }

    /// Resumes a suspended page, in the show's turn before the view is visible. WebKit clears its flag
    /// in this call, so the same turn may call into the page.
    ///
    /// - Returns: False, with no call into WebKit, when the page is not suspended.
    @discardableResult
    func resumePage(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard let spi = Self.pageSuspendSPI, spi.isSuspended(self) else { return false }
        spi.send(spi.resume, to: self, done)
        return true
    }
}

/// WebKit's `_suspendPage:`, `_resumePage:` and `_isSuspended`, each called only through the IMP
/// `class_getInstanceMethod` found, so a WebKit without one never gets an unknown selector.
struct PageSuspendSPI {
    typealias Reply = @convention(block) (ObjCBool) -> Void
    typealias Send = @convention(c) (AnyObject, Selector, Reply) -> Void
    typealias Read = @convention(c) (AnyObject, Selector) -> ObjCBool

    let suspend: (selector: Selector, call: Send)
    let resume: (selector: Selector, call: Send)
    let isSuspendedRead: (selector: Selector, call: Read)

    /// Nil when `type` lacks any of the three methods.
    init?(in type: AnyClass, suspend: String = "_suspendPage:", resume: String = "_resumePage:",
          isSuspended: String = "_isSuspended") {
        func method(_ name: String) -> (Selector, IMP)? {
            // crash-allow: WebKit private selector, called only through the IMP class_getInstanceMethod found (no unknown-selector exception).
            let selector = NSSelectorFromString(name)
            return class_getInstanceMethod(type, selector).map { (selector, method_getImplementation($0)) }
        }
        guard let suspendMethod = method(suspend), let resumeMethod = method(resume),
              let readMethod = method(isSuspended) else { return nil }
        self.suspend = (suspendMethod.0, unsafeBitCast(suspendMethod.1, to: Send.self))
        self.resume = (resumeMethod.0, unsafeBitCast(resumeMethod.1, to: Send.self))
        self.isSuspendedRead = (readMethod.0, unsafeBitCast(readMethod.1, to: Read.self))
    }

    @MainActor func isSuspended(_ view: AnyObject) -> Bool {
        isSuspendedRead.call(view, isSuspendedRead.selector).boolValue
    }

    /// WebKit runs the reply on the main thread (its IPC replies arrive on the UI process's main run loop).
    @MainActor func send(_ method: (selector: Selector, call: Send), to view: AnyObject,
                         _ done: @escaping @MainActor (Bool) -> Void) {
        let reply: Reply = { ok in
            MainActor.assumeIsolated { done(ok.boolValue) } // main-proof: WebKit replies on the main run loop
        }
        method.call(view, method.selector, reply)
    }
}

/// How a hidden, frozen WebKit page is parked (p13-webui.md 3.C, spike 029), chosen from a live
/// measurement of each mode on the same page: its web process's wakeups per second while parked and
/// the main-thread time of the turn that shows it again (`PageWebKitParkingBench`). Hidden in the
/// window (p13-webui-028) is the default. Suspended wins only when it wakes less within the show-turn
/// budget. Detached wins only when hidden in the window wakes more than ``detachWakeupFloor`` and
/// detaching wakes less within the budget. Chrome freezes a hidden page where it is and never moves
/// its view (`WebContents::SetPageFrozen`, content/public/browser/web_contents.h).
enum PageWebKitParking: String, CaseIterable, Sendable {
    case hiddenInWindow
    case suspended
    case detached

    /// One mode's live numbers.
    struct Measurement: Sendable, Equatable {
        /// Interrupt wakeups per second of the page's web process while parked.
        var wakeupsPerSecond: Double
        /// Main-thread time of the turn that shows the page again.
        var showTurn: Duration
    }

    /// Hidden-in-window wakeups per second at or under which a detach is never used.
    static let detachWakeupFloor = 0.2
    /// The most main-thread time the show's turn may take for a mode other than hidden in the window.
    static let showTurnBudget: Duration = .milliseconds(4)

    /// The mode the numbers pick. A nil measurement is a mode not measured (no SPI, or not run).
    static func choose(hiddenInWindow: Measurement, suspended: Measurement?, detached: Measurement?) -> Self {
        var pick = (mode: Self.hiddenInWindow, wakeups: hiddenInWindow.wakeupsPerSecond)
        if let suspended, suspended.showTurn <= showTurnBudget, suspended.wakeupsPerSecond < pick.wakeups {
            pick = (.suspended, suspended.wakeupsPerSecond)
        }
        if hiddenInWindow.wakeupsPerSecond > detachWakeupFloor, let detached,
           detached.showTurn <= showTurnBudget, detached.wakeupsPerSecond < pick.wakeups {
            pick = (.detached, detached.wakeupsPerSecond)
        }
        return pick.mode
    }
}

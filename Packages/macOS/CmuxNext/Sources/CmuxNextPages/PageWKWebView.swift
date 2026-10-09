import AppKit
import Foundation
import WebKit

/// The WebKit view of every first-party page (DESKTOP-FEEL, R139): the host half of the shared
/// desktop layer (the web half is webviews/src/pages/shared/desktop.ts). A page is app chrome:
/// - no pinch or smart magnification (the UI scale comes from the app);
/// - the native context menu offers only Copy, and only on a selection (a page that draws its own
///   menu cancels `contextmenu`, so WebKit shows none);
/// - Select All acts only inside the focused field, never over the whole page.
/// Swipe navigation and link previews are off in ``PageWebView``. Third-party pages in browser tabs
/// use their own views and are not affected.
final class PageWKWebView: WKWebView {
    var onUserEvent: (() -> Void)?
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
        NotificationCenter.default.addObserver(self, selector: #selector(menuWillSendAction(_:)),
                                               name: NSMenu.willSendActionNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// When a real key or mouse event last reached this view (`systemUptime`): a page call shortly
    /// after it is backed by the person's gesture (``hasRecentUserGesture(within:)``). Page script
    /// cannot set it.
    private(set) var lastUserEventUptime: TimeInterval?

    /// Whether a key or mouse event reached the view within `seconds`.
    func hasRecentUserGesture(within seconds: TimeInterval = 1, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let last = lastUserEventUptime else { return false }
        return now - last <= seconds
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
    @objc private func menuWillSendAction(_ notification: Notification) {
        guard let opened = openedMenu, var menu = notification.object as? NSMenu else { return }
        while menu !== opened {
            guard let parent = menu.supermenu else { return }
            menu = parent
        }
        noteUserActivation(at: ProcessInfo.processInfo.systemUptime)
    }

    override func keyDown(with event: NSEvent) { noteUserEvent(event); super.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { noteUserEvent(event); super.keyUp(with: event) }
    override func mouseDown(with event: NSEvent) { noteUserEvent(event); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { noteUserEvent(event); super.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { noteUserEvent(event); super.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { noteUserEvent(event); super.rightMouseDown(with: event) }

    /// Replaces the Copy-only menu when set (``PageWebView/contextMenuEditor``).
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        openedMenu = menu
        if let contextMenuEditor { contextMenuEditor(menu) } else { Self.keepDesktopItems(in: menu) }
        super.willOpenMenu(menu, with: event)
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

    private func droppedFile(_ info: any NSDraggingInfo) -> URL? {
        guard let fileDrop,
              let url = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true])?.first as? URL,
              fileDrop.accepts(url) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = droppedFile(sender), let fileDrop else { return super.performDragOperation(sender) }
        fileDrop.open(url)
        return true
    }
}

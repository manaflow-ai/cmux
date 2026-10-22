import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import Observation
import UniformTypeIdentifiers
import CmuxNextWakeups

/// The toolbar's Downloads popup (`browser.downloads.show`, Chrome's
/// download bubble): a popup of the shared native host (`NativePopupHost`)
/// under the Downloads button, right-aligned to it, newest download first.
/// A finished row opens its file on a click and drags out as that file (a
/// terminal takes it as its path); a right-click gives the row's menu
/// (`BrowserDownloadsMenu.actions`). It also opens by itself when a
/// download finishes in a visible tab (`showFinished`), as Chrome's partial
/// view does, and closes again after `autoCloseDelay` unless the pointer
/// went into it. Chromium's own bubble is off (`shim_process.mm`): it
/// anchors to a toolbar cmux never shows, so it opened over the page.
@MainActor
final class BrowserDownloadsPopup {
    static let shared = BrowserDownloadsPopup()

    /// How long a popup that opened by itself stays without the pointer (Chrome: 5 s).
    static let autoCloseDelay: Duration = .seconds(5)
    /// Rows listed; the list keeps more (`BrowserDownloadList.limit`).
    static let shown = 12

    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.browser.downloads"))
    private let model = BrowserDownloadsPopupModel()
    private var content: BrowserDownloadsPopupView?
    private weak var anchor: NSView?
    /// The toolbar the popup opened from, which draws its button pressed while it is open.
    private weak var buttons: BrowserToolbarButtonsView?
    /// The automatic close of a popup that opened by itself.
    private let autoClose = DemandTimer(owner: "Browser.downloadsPopup")

    private init() {
        popup.onDismiss = { [weak self] in self?.closed() }
        model.onEnter = { [weak self] in self?.cancelAutoClose() }
    }

    var isShown: Bool { popup.isShown }

    /// The popup's card on screen (`debug.downloads`, tests).
    var shownFrame: CGRect? { popup.isShown ? popup.cardFrame : nil }

    /// The Downloads button: opens the popup, or closes it when it is open there.
    func toggle(_ list: BrowserDownloadList, buttons: BrowserToolbarButtonsView, showFolder: @escaping () -> Void) {
        guard let anchor = buttons.popupAnchor(for: .downloads) else { return }
        if popup.isShown, self.anchor === anchor { return close() }
        show(list, anchor: anchor, buttons: buttons, showFolder: showFolder, makeKey: true)
    }

    /// A download finished in a tab whose toolbar is on screen: opens the
    /// popup there without the keys (typing stays where it was) and closes
    /// it after `autoCloseDelay`. False when it cannot show (the tab is
    /// hidden, the app or its window is not active), so the caller falls
    /// back to the notice over the tab.
    @discardableResult
    func showFinished(_ list: BrowserDownloadList, buttons: BrowserToolbarButtonsView, showFolder: @escaping () -> Void) -> Bool {
        // The Downloads button itself, or More when it is collapsed; never the bare toolbar.
        guard NSApp.isActive, let anchor = buttons.popupAnchor(for: .downloads), anchor !== buttons.superview,
              let window = anchor.window, window.isKeyWindow || window.isMainWindow,
              !anchor.isHiddenOrHasHiddenAncestor else { return false }
        // Already open (a click, or another download): it stays as it is and lists the new row.
        if popup.isShown { return true }
        guard show(list, anchor: anchor, buttons: buttons, showFolder: showFolder, makeKey: false) else { return false }
        model.entered = false
        autoClose.schedule(after: Self.autoCloseDelay) { @MainActor [weak self] in
            guard let self, !self.model.entered else { return }
            self.close()
        }
        return true
    }

    func close() {
        popup.hide()
        closed()
    }

    @discardableResult
    private func show(_ list: BrowserDownloadList, anchor: NSView, buttons: BrowserToolbarButtonsView,
                      showFolder: @escaping () -> Void, makeKey: Bool) -> Bool {
        guard let window = anchor.window else { return false }
        cancelAutoClose()
        generation += 1
        if let old = self.anchor, old !== anchor { self.buttons?.setPopupOpen(false, anchor: old) }
        self.anchor = anchor
        self.buttons = buttons
        model.list = list
        if !popup.isShown { model.shows += 1 }
        model.colors = anchor.performWithTheme { BrowserDownloadsPopupColors.resolve() }
        model.onShowFolder = { [weak self] in
            self?.close()
            showFolder()
        }
        model.onOpen = { [weak self] file in
            self?.close()
            NSWorkspace.shared.openInBackground(file)
        }
        model.onReveal = { [weak self] file in
            self?.close()
            NSWorkspace.shared.revealInBackground([file])
        }
        let content = content ?? makeContent()
        content.reload()
        popup.panel.adoptThemeScope(of: anchor)
        // A press on the Downloads button toggles the popup: the button closes it, not the click monitor.
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        let size = content.fittingSize
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        guard popup.show(size: CGSize(width: ceil(size.width), height: ceil(size.height)), anchor: rect, in: window,
                         preferred: .below, trailing: true, makeKey: makeKey) != nil else { return false }
        buttons.setPopupOpen(true, anchor: anchor)
        buttons.onDetach = { [weak self] in self?.close() }
        followRows()
        return true
    }

    private func makeContent() -> BrowserDownloadsPopupView {
        let content = BrowserDownloadsPopupView(model: model)
        let card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        self.content = content
        return content
    }

    /// Bumped by every show and close: an observation of an earlier show stops.
    private var generation = 0

    /// While the popup shows, a row added or removed resizes it under the button.
    private func followRows() {
        guard popup.isShown, let list = model.list else { return }
        let current = generation
        let model = model
        // The Clear row comes and goes with the finished rows, without a row count change.
        _ = withObservationTracking { (list.items.count, model.canClear) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.resize()
            }
        }
    }

    private func resize() {
        guard popup.isShown, let content else { return }
        // The button left the screen (another tab, the tab closed): the popup goes with it.
        guard let anchor, let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else { return close() }
        content.reload()
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        popup.show(size: CGSize(width: ceil(size.width), height: ceil(size.height)), anchor: rect, in: window,
                   preferred: .below, trailing: true, makeKey: popup.panel.isKeyWindow)
        followRows()
    }

    private func cancelAutoClose() { autoClose.cancel() }

    private func closed() {
        cancelAutoClose()
        generation += 1
        buttons?.onDetach = nil
        if let anchor { buttons?.setPopupOpen(false, anchor: anchor) }
        anchor = nil
    }
}

/// What the popup's rows read and the callbacks they run.
@MainActor
@Observable
final class BrowserDownloadsPopupModel {
    var list: BrowserDownloadList?
    var colors = BrowserDownloadsPopupColors()
    /// The pointer went into the popup: it no longer closes by itself.
    var entered = false
    /// Bumped by every show: the rows are built again, so no row keeps the
    /// hover of the last show (the pointer left it while the popup was closed).
    var shows = 0
    @ObservationIgnored var onEnter: () -> Void = {}
    @ObservationIgnored var onOpen: (URL) -> Void = { _ in }
    @ObservationIgnored var onShowFolder: () -> Void = {}
    @ObservationIgnored var onReveal: (URL) -> Void = { _ in }

    var rows: [BrowserDownload] { Array((list?.items ?? []).suffix(BrowserDownloadsPopup.shown).reversed()) }

    var canClear: Bool { list?.items.contains { $0.status != .inProgress } ?? false }

    func clear() { list?.clearEnded() }

    func menu(for download: BrowserDownload) -> NSMenu? {
        guard let list else { return nil }
        return BrowserDownloadsMenu.actions(download, list: list)
    }

    func pointerEntered() {
        entered = true
        onEnter()
    }
}

final class BrowserDownloadRowEventView: NSView, NSDraggingSource {
    var fileProvider: () -> URL? = { nil }
    var menuProvider: () -> NSMenu? = { nil }
    var onOpen: (URL) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    private var downEvent: NSEvent?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down = downEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 3, let file = fileProvider() else { return }
        dragged = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: file.path(percentEncoded: false))
        icon.size = NSSize(width: 32, height: 32)
        let point = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)), let file = fileProvider() else { return }
        onOpen(file)
    }

    /// The row's right-click menu in the cmux NEXT menu look, in this row's theme.
    func themedMenu() -> NSMenu? { menuProvider()?.themeRows(in: themeScope.fullStrength) }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = themedMenu() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.copy, .generic, .link]
    }
}

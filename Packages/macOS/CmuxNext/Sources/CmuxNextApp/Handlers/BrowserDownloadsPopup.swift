import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import Observation
import SwiftUI
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
    private var content: NSHostingView<BrowserDownloadsPopupView>?
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
        if let old = self.anchor, old !== anchor { self.buttons?.setPopupOpen(false, anchor: old) }
        self.anchor = anchor
        self.buttons = buttons
        model.list = list
        model.colors = anchor.performWithTheme { BrowserDownloadsPopupColors.resolve() }
        model.onShowFolder = { [weak self] in
            self?.close()
            showFolder()
        }
        model.onOpen = { [weak self] file in
            self?.close()
            NSWorkspace.shared.openInBackground(file)
        }
        let content = content ?? makeContent()
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
        followRows()
        return true
    }

    private func makeContent() -> NSHostingView<BrowserDownloadsPopupView> {
        let content = NSHostingView(rootView: BrowserDownloadsPopupView(model: model))
        let card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        self.content = content
        return content
    }

    /// While the popup shows, a row added or removed resizes it under the button.
    private func followRows() {
        guard popup.isShown, let list = model.list else { return }
        let count = withObservationTracking { list.items.count } onChange: { [weak self] in
            Task { @MainActor in self?.resize() }
        }
        _ = count
    }

    private func resize() {
        guard popup.isShown, let anchor, let window = anchor.window, let content else { return }
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
        if let anchor { buttons?.setPopupOpen(false, anchor: anchor) }
        anchor = nil
    }
}

/// What the popup's SwiftUI rows read and the callbacks they run.
@MainActor
@Observable
final class BrowserDownloadsPopupModel {
    var list: BrowserDownloadList?
    var colors = BrowserDownloadsPopupColors()
    /// The pointer went into the popup: it no longer closes by itself.
    var entered = false
    @ObservationIgnored var onEnter: () -> Void = {}
    @ObservationIgnored var onOpen: (URL) -> Void = { _ in }
    @ObservationIgnored var onShowFolder: () -> Void = {}

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

/// The popup's colors from the toolbar's theme scope (as `BookmarkPageColors`).
struct BrowserDownloadsPopupColors: Equatable {
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var separator = Color(nsColor: Borders.color(ThemeTokens.unresolved.separator.nsColor))
    var danger = ThemeTokens.unresolved.danger.swiftUIColor

    /// Call inside `performWithTheme`. theme-scoped
    static func resolve() -> BrowserDownloadsPopupColors {
        BrowserDownloadsPopupColors(primary: fixed(Palette.textPrimary), secondary: fixed(Palette.textSecondary),
                                    hover: fixed(Palette.hoverFill), separator: fixed(Palette.separator),
                                    danger: fixed(Palette.danger))
    }

    private static func fixed(_ color: NSColor) -> Color {
        Color(nsColor: color.usingColorSpace(.sRGB) ?? color)
    }
}

struct BrowserDownloadsPopupView: View {
    let model: BrowserDownloadsPopupModel

    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 6

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(BrowserHitStrings.downloadsEmpty)
                    .font(Font(Typography.body))
                    .foregroundStyle(model.colors.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { download in
                            BrowserDownloadPopupRow(download: download, model: model)
                                .frame(height: Self.rowHeight)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: CGFloat(min(rows.count, Self.visibleRows)) * Self.rowHeight + 8)
            }
            Rectangle().fill(model.colors.separator).frame(height: 1)
            HStack(spacing: 8) {
                Button(BrowserHitStrings.downloadsShowFolder) { model.onShowFolder() }
                    .buttonStyle(.borderless)
                Spacer(minLength: 0)
                if model.canClear {
                    Button(BrowserHitStrings.downloadsClear) { model.clear() }
                        .buttonStyle(.borderless)
                }
            }
            .font(Font(Typography.body))
            .foregroundStyle(model.colors.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onHover { inside in if inside { model.pointerEntered() } }
        .accessibilityIdentifier("browser.downloads.popup")
    }
}

/// One download: its icon, name and status. Pointer handling is AppKit
/// (`BrowserDownloadRowEvents`): a SwiftUI drag source in a nonactivating
/// panel needed a first click to make the panel key.
private struct BrowserDownloadPopupRow: View {
    let download: BrowserDownload
    let model: BrowserDownloadsPopupModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: BrowserDownloadsMenu.icon(for: download, size: 24))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(download.filename)
                    .font(Font(Typography.body))
                    .foregroundStyle(model.colors.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(BrowserDownloadsMenu.status(download))
                    .font(Font(Typography.caption))
                    .foregroundStyle(download.status == .failed ? model.colors.danger : model.colors.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? model.colors.hover : Color.clear))
        .padding(.horizontal, 4)
        .overlay(BrowserDownloadRowEvents(
            file: BrowserDownloadsMenu.draggableFile(download),
            menu: { model.menu(for: download) },
            open: { file in model.onOpen(file) },
            hover: { inside in
                hovered = inside
                if inside { model.pointerEntered() }
            }
        ))
        .help(download.filename)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.downloads.row")
    }
}

/// The row's pointer: a click opens the finished file, a drag carries it
/// out as a file URL, a right-click shows the row's menu.
private struct BrowserDownloadRowEvents: NSViewRepresentable {
    let file: URL?
    let menu: () -> NSMenu?
    let open: (URL) -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> BrowserDownloadRowEventView { BrowserDownloadRowEventView() }

    func updateNSView(_ view: BrowserDownloadRowEventView, context: Context) {
        view.file = file
        view.menuProvider = menu
        view.onOpen = open
        view.onHover = hover
    }
}

final class BrowserDownloadRowEventView: NSView, NSDraggingSource {
    var file: URL?
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
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
        guard !dragged, let down = downEvent, let file else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
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
        guard !dragged, let file, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen(file)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.copy, .generic, .link]
    }
}

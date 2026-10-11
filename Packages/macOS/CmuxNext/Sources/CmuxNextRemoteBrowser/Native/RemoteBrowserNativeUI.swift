public import AppKit

#if DEBUG
/// The native macOS UI of a remote tab, built from the client reducer's
/// effects (RT5): the page's context menu and `<select>` as an `NSMenu`, a
/// JavaScript dialog as a sheet on the pane's window, and the page cursor
/// as an `NSCursor`. Each answer goes back through `onMenuChoice` and
/// `onDialogAnswer` with the token the effect named; the reducer drops
/// answers for tokens that are no longer open.
@MainActor
public final class RemoteBrowserNativeUI: NSObject {
    public var onMenuChoice: ((UInt64, RbMenuChoice) -> Void)?
    public var onDialogAnswer: ((UInt64, Bool, String?) -> Void)?
    private weak var view: RemoteBrowserContentView?
    /// The open menu and its token (at most one, like Chrome).
    private var openMenu: (token: UInt64, menu: NSMenu)?
    private var chosen: RbMenuChoice?
    private var openDialog: (token: UInt64, alert: NSAlert)?

    public init(view: RemoteBrowserContentView) {
        self.view = view
    }

    /// The menu the reducer has open, for tests and the debug socket.
    public var openMenuTitles: [String]? { openMenu?.menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
    public var openDialogToken: UInt64? { openDialog?.token }

    // MARK: Menus

    /// Builds the menu and pops it up at the anchor (pane points equal the
    /// page's CSS pixels). `popUp` tracks until the person picks or
    /// dismisses; the answer is sent once it returns.
    public func showMenu(token: UInt64, menu model: RbMenu) {
        guard let view else { return onMenuChoice?(token, .cancel) ?? () }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in model.items { menu.addItem(makeItem(item, select: model.kind == "select")) }
        openMenu = (token, menu)
        chosen = nil
        let anchor = NSPoint(x: model.anchor.x, y: model.anchor.y + model.anchor.height)
        let selected = model.kind == "select" ? model.selected.flatMap { index in menu.items.first { $0.tag == Int(index) } } : nil
        _ = menu.popUp(positioning: selected, at: anchor, in: view)
        guard openMenu?.token == token else { return }
        openMenu = nil
        onMenuChoice?(token, chosen ?? .cancel)
    }

    /// The host or the reducer closed the menu (`close_menu`).
    public func closeMenu(token: UInt64) {
        guard let open = openMenu, open.token == token else { return }
        openMenu = nil
        open.menu.cancelTrackingWithoutAnimation()
    }

    /// Answers the open menu as if the person picked `choice` (the debug
    /// socket's live proofs); the answer goes out when tracking ends.
    @discardableResult
    public func choose(_ choice: RbMenuChoice) -> Bool {
        guard let open = openMenu else { return false }
        chosen = choice
        open.menu.cancelTracking()
        return true
    }

    private func makeItem(_ model: RbMenuItem, select: Bool) -> NSMenuItem {
        if model.type == "separator" { return .separator() }
        let item = NSMenuItem(title: model.label, action: nil, keyEquivalent: "")
        item.isEnabled = model.enabled
        item.tag = Int(model.id)
        item.state = model.checked ? .on : .off
        if model.type == "submenu" || model.type == "group" {
            let submenu = NSMenu(title: model.label)
            submenu.autoenablesItems = false
            for child in model.items { submenu.addItem(makeItem(child, select: select)) }
            if model.type == "submenu" { item.submenu = submenu } else { item.isEnabled = false }
            return item
        }
        item.target = self
        item.action = select ? #selector(selectOption(_:)) : #selector(runCommand(_:))
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) { chosen = .command(Int64(sender.tag)) }
    @objc private func selectOption(_ sender: NSMenuItem) { chosen = .indices([UInt32(clamping: sender.tag)]) }

    // MARK: Dialogs

    /// A JavaScript dialog as a sheet on the pane's window.
    public func showDialog(token: UInt64, dialog: RbDialog) {
        guard let window = view?.window else { return onDialogAnswer?(token, false, nil) ?? () }
        let alert = NSAlert()
        alert.messageText = dialog.origin
        alert.informativeText = dialog.message
        let ok = String(localized: "remoteBrowser.dialog.ok", defaultValue: "OK", bundle: .module)
        let cancel = String(localized: "remoteBrowser.dialog.cancel", defaultValue: "Cancel", bundle: .module)
        let field: NSTextField?
        switch dialog.kind {
        case "alert":
            alert.addButton(withTitle: ok)
            field = nil
        case "prompt":
            alert.addButton(withTitle: ok)
            alert.addButton(withTitle: cancel)
            let input = NSTextField(string: dialog.defaultText ?? "")
            input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = input
            field = input
        case "beforeunload":
            alert.addButton(withTitle: dialog.isReload
                ? String(localized: "remoteBrowser.dialog.reload", defaultValue: "Reload", bundle: .module)
                : String(localized: "remoteBrowser.dialog.leave", defaultValue: "Leave", bundle: .module))
            alert.addButton(withTitle: cancel)
            field = nil
        default:
            alert.addButton(withTitle: ok)
            alert.addButton(withTitle: cancel)
            field = nil
        }
        openDialog = (token, alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, openDialog?.token == token else { return }
            openDialog = nil
            let accept = response == .alertFirstButtonReturn
            onDialogAnswer?(token, accept, accept ? field?.stringValue : nil)
        }
    }

    /// The host or the reducer closed the dialog (`close_dialog`): the sheet
    /// goes away without an answer.
    public func closeDialog(token: UInt64) {
        guard let open = openDialog, open.token == token else { return }
        openDialog = nil
        if let sheet = open.alert.window.sheetParent { sheet.endSheet(open.alert.window) }
    }

    // MARK: Cursor

    /// The last page cursor's CSS name (debug socket).
    public private(set) var cursorKind: String?

    /// The page cursor (`rb.cursor`), as a CSS cursor name.
    public func setCursor(kind: String) {
        cursorKind = kind
        view?.pageCursor = RemoteBrowserCursorShape(css: kind).cursor
    }
}
#endif

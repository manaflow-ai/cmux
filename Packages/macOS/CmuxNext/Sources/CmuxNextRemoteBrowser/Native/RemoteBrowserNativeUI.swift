public import AppKit
public import CmuxNextDesign

#if DEBUG || CMUX_BENCH_HOOKS
/// The native macOS UI of a remote tab, built from the client reducer's
/// effects (RT5): the page's context menu and `<select>` as an `NSMenu`, a
/// JavaScript dialog as the cmux dialog over the tab, and the page cursor
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
    /// The open dialog's token and its cmux dialog id.
    private var openDialog: (token: UInt64, id: Int)?
    private let dialogs: CmuxDialogCenter

    public init(view: RemoteBrowserContentView, dialogs: CmuxDialogCenter = .shared) {
        self.view = view
        self.dialogs = dialogs
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

    /// A JavaScript dialog as the themed cmux dialog over the tab (an `NSAlert` sheet's chrome
    /// can't take the room's theme). Return accepts (a prompt answers its text), Escape declines.
    public func showDialog(token: UInt64, dialog: RbDialog) {
        guard let view, view.window != nil else { return onDialogAnswer?(token, false, nil) ?? () }
        if let open = openDialog {
            openDialog = nil
            dialogs.dismiss(open.id)
        }
        let id = dialogs.present(Self.spec(for: dialog), in: .tab(view)) { [weak self] answer in
            guard let self, openDialog?.token == token else { return }
            openDialog = nil
            let accept = !answer.isDismissal && answer.role == .default
            onDialogAnswer?(token, accept, accept && dialog.kind == "prompt" ? answer.values[Self.textField]?.text ?? "" : nil)
        }
        // A dialog answered before `present` returned (none today) has already cleared its token.
        if dialogs.record(id) != nil { openDialog = (token, id) }
    }

    /// The prompt's field id.
    static let textField = "text"

    /// The cmux dialog of a page's JavaScript dialog: the page's origin as the title, its message as
    /// the line, and the buttons Chrome shows for that kind.
    static func spec(for dialog: RbDialog) -> CmuxDialogSpec {
        let ok = String(localized: "remoteBrowser.dialog.ok", defaultValue: "OK", bundle: .module)
        let cancel = String(localized: "remoteBrowser.dialog.cancel", defaultValue: "Cancel", bundle: .module)
        var fields: [CmuxDialogField] = []
        let buttons: [CmuxDialogButton]
        switch dialog.kind {
        case "alert":
            buttons = [.ok(ok)]
        case "prompt":
            fields = [.text(textField, initial: dialog.defaultText ?? "")]
            buttons = [.cancel(cancel), .ok(ok)]
        case "beforeunload":
            let leave = dialog.isReload
                ? String(localized: "remoteBrowser.dialog.reload", defaultValue: "Reload", bundle: .module)
                : String(localized: "remoteBrowser.dialog.leave", defaultValue: "Leave", bundle: .module)
            buttons = [.cancel(cancel), .ok(leave)]
        default:
            buttons = [.cancel(cancel), .ok(ok)]
        }
        return CmuxDialogSpec(title: dialog.origin, lines: dialog.message.isEmpty ? [] : [dialog.message], fields: fields,
                              buttons: buttons, identifier: "cmux.remoteBrowser.dialog")
    }

    /// The host or the reducer closed the dialog (`close_dialog`): it goes away without an answer.
    public func closeDialog(token: UInt64) {
        guard let open = openDialog, open.token == token else { return }
        openDialog = nil
        dialogs.dismiss(open.id)
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

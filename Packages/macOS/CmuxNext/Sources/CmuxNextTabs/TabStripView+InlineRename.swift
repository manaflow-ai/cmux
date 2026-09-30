public import AppKit
import CmuxNextDesign

/// State of the strip's inline rename editor.
@MainActor final class TabInlineRename {
    var enabledOnDoubleClick = false
    var field: NSTextField?
    var tabID: TabID?
    var delegate: InlineRenameDelegate?
}

/// Inline rename: an editor over the tab's title. Return and focus loss
/// commit, Escape cancels, as in Finder.
extension TabStripView {
    /// Double-clicking a tab starts inline rename (the screen bar). Off by
    /// default: pane tab strips keep Chrome's behavior.
    public var renamesOnDoubleClick: Bool {
        get { inlineRename.enabledOnDoubleClick }
        set { inlineRename.enabledOnDoubleClick = newValue }
    }

    /// The editor while a rename is open.
    public var inlineRenameField: NSTextField? { inlineRename.field }

    /// Opens the editor over tab `id`, prefilled with its title and fully
    /// selected. Tabs the strip does not show are ignored.
    public func beginInlineRename(_ id: TabID) {
        guard let item = model.tab(id), let cell = cells[id] else { return }
        cancelInlineRename()
        hoverCard.hide(allowsQuickReshow: false)
        let field = NSTextField(string: item.title)
        field.font = Typography.body
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Palette.windowBackground
        field.textColor = Palette.textPrimary
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(Strings.renameField)
        let delegate = InlineRenameDelegate(strip: self)
        field.delegate = delegate
        let inset = metrics.contentLeadingInset
        let height = ceil(Typography.body.ascender - Typography.body.descender) + Metrics.space1
        field.frame = CGRect(x: cell.frame.minX + inset, y: (tabsClip.bounds.height - height) / 2,
                             width: max(cell.frame.width - inset * 2, Metrics.space4 * 4), height: height)
        tabsClip.addSubview(field)
        inlineRename.field = field
        inlineRename.tabID = id
        inlineRename.delegate = delegate
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Sends `renameCommitted` with the trimmed text and closes the editor.
    public func commitInlineRename() {
        guard let field = inlineRename.field, let id = inlineRename.tabID else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        closeInlineRename()
        if model.tab(id)?.title != name { model.send(.renameCommitted(id, name: name)) }
    }

    /// Closes the editor without a change.
    public func cancelInlineRename() {
        closeInlineRename()
    }

    private func closeInlineRename() {
        guard let field = inlineRename.field else { return }
        inlineRename.field = nil
        inlineRename.tabID = nil
        inlineRename.delegate = nil
        field.delegate = nil
        let hadFocus = field.currentEditor() != nil
        field.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(nil) }
    }
}

/// Return and focus loss commit; Escape cancels.
@MainActor final class InlineRenameDelegate: NSObject, NSTextFieldDelegate {
    private weak var strip: TabStripView?

    init(strip: TabStripView) { self.strip = strip }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            strip?.commitInlineRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            strip?.cancelInlineRename()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        strip?.commitInlineRename()
    }
}

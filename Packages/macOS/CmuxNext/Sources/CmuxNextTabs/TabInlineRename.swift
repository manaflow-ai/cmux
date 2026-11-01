public import AppKit
import CmuxNextDesign

/// Inline rename: an editor over the tab's title. Return and focus loss
/// commit, Escape cancels. The strip holds one and forwards its public
/// rename surface here.
@MainActor final class TabInlineRename {
    private weak var strip: TabStripView?
    var enabledOnDoubleClick = false
    private(set) var field: NSTextField?
    private var tabID: TabID?
    private var delegate: InlineRenameDelegate?

    init(strip: TabStripView) { self.strip = strip }

    /// Opens the editor over tab `id`, prefilled with its title and fully
    /// selected. Tabs the strip does not show are ignored.
    func begin(_ id: TabID) {
        guard let strip, let item = strip.model.tab(id), let cell = strip.cells[id] else { return }
        cancel()
        strip.hoverCards.dismiss(.action)
        // Follows theme changes while open (ThemedTextField).
        let field = ThemedTextField(string: item.title)
        field.font = Typography.tabTitle
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(Strings.renameField)
        let delegate = InlineRenameDelegate(rename: self)
        field.delegate = delegate
        let inset = strip.metrics.contentLeadingInset
        let height = ceil(Typography.tabTitle.ascender - Typography.tabTitle.descender) + Metrics.space1
        field.frame = CGRect(x: cell.frame.minX + inset, y: (strip.tabsClip.bounds.height - height) / 2,
                             width: max(cell.frame.width - inset * 2, Metrics.space4 * 4), height: height)
        strip.tabsClip.addSubview(field)
        self.field = field
        tabID = id
        self.delegate = delegate
        strip.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Sends `renameCommitted` with the trimmed text and closes the editor.
    func commit() {
        guard let field, let id = tabID else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        guard let model = strip?.model else { return }
        guard model.tab(id)?.title != name else { return }
        // The editor already showed the new name: its echo swaps without the rename crossfade.
        strip?.cells[id]?.directTitle = name
        model.send(.renameCommitted(id, name: name))
    }

    /// Closes the editor without a change.
    func cancel() {
        close()
    }

    private func close() {
        guard let field else { return }
        self.field = nil
        tabID = nil
        delegate = nil
        field.delegate = nil
        let hadFocus = field.currentEditor() != nil
        field.removeFromSuperview()
        if hadFocus { strip?.window?.makeFirstResponder(nil) }
    }
}

/// The strip's public rename surface (`TabInlineRename`).
extension TabStripView {
    /// Double-clicking a tab starts inline rename (the screen bar). Off by
    /// default: a pane tab strip's double-click zooms the pane (`toggleZoom`).
    public var renamesOnDoubleClick: Bool {
        get { inlineRename.enabledOnDoubleClick }
        set { inlineRename.enabledOnDoubleClick = newValue }
    }

    /// The editor while a rename is open.
    public var inlineRenameField: NSTextField? { inlineRename.field }
    /// Opens the editor over tab `id` (`TabInlineRename.begin`).
    public func beginInlineRename(_ id: TabID) { inlineRename.begin(id) }
    /// Sends `renameCommitted` with the trimmed text and closes the editor.
    public func commitInlineRename() { inlineRename.commit() }
    /// Closes the editor without a change.
    public func cancelInlineRename() { inlineRename.cancel() }
}

/// Return and focus loss commit; Escape cancels.
@MainActor final class InlineRenameDelegate: NSObject, NSTextFieldDelegate {
    private weak var rename: TabInlineRename?

    init(rename: TabInlineRename) { self.rename = rename }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            rename?.commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            rename?.cancel()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        rename?.commit()
    }
}

import AppKit
import CmuxNextDesign
import QuartzCore

// Inline rename of workspaces and groups.

extension SidebarListView {
    // MARK: - Rename

    struct Rename {
        var key: SidebarRowKey
        var field: NSTextField
        var original: String
        var cancelled = false
    }

    func beginRename(_ key: SidebarRowKey) {
        guard !compact, drag == nil else { return }
        if rename != nil { endRename(commit: true) }
        let original: String
        switch key {
        case let .workspace(id): original = workspaces[id]?.title ?? ""
        case let .group(id): original = groups[id]?.name ?? ""
        default: return
        }
        if let row = displayed.row(for: key) { scrollToVisible(frame(for: row)) }
        realizeVisibleRows()
        guard let view = rowViews[key] else { return }
        let titleFrame = convert(view.titleFrame, from: view)
        let field = NSTextField(string: original)
        field.font = view.titleFont
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Palette.hoverFill
        field.textColor = Palette.textPrimary
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = Metrics.space2
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(
            x: titleFrame.minX - Metrics.space1,
            y: titleFrame.midY - height / 2,
            width: max(Metrics.sidebarCollapsedWidth, view.frame.width - titleFrame.minX - Metrics.space3),
            height: height
        )
        addSubview(field)
        view.setTitleHidden(true)
        rename = Rename(key: key, field: field, original: original)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endRename(commit: Bool) {
        guard let rename else { return }
        self.rename = nil
        rename.field.delegate = nil
        rename.field.removeFromSuperview()
        rowViews[rename.key]?.setTitleHidden(false)
        let text = rename.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit, !rename.cancelled, !text.isEmpty, text != rename.original {
            switch rename.key {
            case let .workspace(id): model.send(.rename(id, text))
            case let .group(id): model.send(.renameGroup(id, text))
            default: break
            }
            reload(animated: false)
        }
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard rename?.field === control else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            rename?.cancelled = true
            endRename(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rename?.field === field else { return }
        endRename(commit: true)
    }
}

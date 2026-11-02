import AppKit
import CmuxNextDesign

/// Inline rename of a workspace or group row: owns the editing field, its
/// delegate, and the commit or cancel decision. The list holds one and
/// asks it to begin; a commit goes out as a model intent.
@MainActor
final class SidebarInlineRename: NSObject, NSTextFieldDelegate {
    struct Session {
        var key: SidebarRowKey
        var field: NSTextField
        var original: String
        var cancelled = false
    }

    weak var list: SidebarListView?
    /// The rename in progress.
    var session: Session?
    /// A rename ended; `byKeyboard` for Return, Escape or Tab (a click
    /// elsewhere already moved focus).
    var onEnded: ((_ byKeyboard: Bool) -> Void)?

    var isActive: Bool { session != nil }
    /// A member of the group being renamed right after a drop made it: the
    /// store may replace the new group under another id, and the rename follows.
    private var groupMember: WorkspaceID?

    /// Renames the group `member` belongs to (drag to group).
    func beginGroup(of member: WorkspaceID) {
        list.map { SidebarGroupEditing(list: $0).open(containing: member) }
    }

    /// After a reload: moves a rename whose group the store replaced to
    /// the group its member is in now, keeping what was typed.
    func follow() {
        guard let member = groupMember, let current = session, case let .group(id) = current.key, list?.groups[id] == nil else { return }
        current.field.delegate = nil
        current.field.removeFromSuperview()
        session = nil
        guard let group = group(containing: member) else { return end(commit: false) }
        begin(.group(group), inPlace: true)
        session?.field.stringValue = current.field.stringValue
        session?.original = current.original
        groupMember = member
    }

    private func group(containing member: WorkspaceID) -> GroupID? {
        list?.groups.values.first { $0.workspaces.contains { $0.id == member } }?.id
    }

    /// Opens the editor over `key`'s title. A group's name is edited in the group editor
    /// (cx-rcby: Return, the menu, a drop) unless `inPlace` (a double-click on the name).
    ///
    /// The editor takes the title's place exactly (user 2026-10-31: "double click to rename
    /// workspaces must not have layout shift"): its text starts on the title's first glyph and
    /// baseline in the title's font and ink, and no row moves or resizes.
    func begin(_ key: SidebarRowKey, inPlace: Bool = false) {
        guard let list, list.model.presentation == .shown, list.drag == nil else { return }
        if case let .group(id) = key, !inPlace || SidebarGroup.hostMachine(id) != nil { return list.groupEditing.open(id) }
        if session != nil { end(commit: true) }
        let original: String
        switch key {
        case let .workspace(id): original = list.workspaces[id]?.title ?? ""
        case let .group(id): original = list.groups[id]?.name ?? ""
        case .section, .emptySection, .emptyGroup, .folder, .item, .block, .doneFold, .showMore, .status: return
        }
        if let row = list.displayed.row(for: key) { list.scrollToVisible(list.frame(for: row)) }
        list.realizeVisibleRows()
        guard let view = list.rowViews[key] else { return }
        if list.groupEditor.isVisible { list.groupEditor.hide() }
        // The row's settled frame, not the view's: a row that just appeared (a group made by a drop) is still animating in.
        let rowFrame = list.displayed.row(for: key).map(list.frame(for:)) ?? view.frame
        view.layoutSubtreeIfNeeded()
        let titleFrame = view.titleFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let pen = view.titlePenOrigin.map { $0.pointValue }.map { NSPoint(x: $0.x + rowFrame.minX, y: $0.y + rowFrame.minY) }
        let maxX = rowFrame.minX + view.titleEditMaxX
        // A group's name sits on its bar: the editor draws no fill over it.
        let onBar: Bool = if case .group = key { true } else { false }
        // Follows theme changes while open (ThemedTextField).
        let field = ThemedTextField(string: original)
        // theme-scoped: ThemedTextField resolves its fill and ink inside performWithTheme.
        if onBar { field.fill = { .clear } } else { field.fill = { Palette.hoverFill } }
        field.ink = { @MainActor [weak view] in view?.titleInk ?? Palette.textPrimary }
        field.font = view.titleFont
        field.isBordered = false
        field.drawsBackground = !onBar
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = Metrics.space2
        let height = ceil(field.intrinsicContentSize.height)
        let x = titleFrame.minX - Metrics.space1
        field.frame = NSRect(x: x, y: titleFrame.midY - height / 2, width: max(0, maxX - x), height: height)
        list.addSubview(field)
        session = Session(key: key, field: field, original: original)
        list.window?.makeFirstResponder(field)
        if let pen { align(field, pen: pen, maxX: maxX) }
        view.setTitleHidden(true)
        field.currentEditor()?.selectAll(nil)
    }

    /// Moves `field` so its editor's text starts at `pen` (the title's first glyph on its
    /// baseline, in list coordinates), keeping its trailing edge at `maxX`. Measured from the
    /// field editor's own layout, so AppKit's insets (cell inset, line fragment padding) never
    /// shift the text.
    private func align(_ field: NSTextField, pen: NSPoint, maxX: CGFloat) {
        guard let list, let start = Self.textOrigin(of: field) else { return }
        let at = list.convert(start, from: field)
        var frame = field.frame
        frame.origin.x += pen.x - at.x
        frame.origin.y += pen.y - at.y
        frame.size.width = max(0, maxX - frame.minX)
        // The field's top on a whole device pixel. AppKit puts the field editor on whole pixels and re-places it when
        // the field sits between them, so a field left on a fractional y (a title centered on its capitals, #27598)
        // drew its text a whole pixel off the title's. Snapped, the text lands within half a pixel of the title's.
        let scale = list.window?.backingScaleFactor ?? 2
        var top = list.convert(frame.origin, to: nil)
        top.y = (top.y * scale).rounded() / scale
        frame.origin.y = list.convert(top, from: nil).y
        field.frame = frame
        // The editor's own offset in the field is not a whole pixel, so the snapped field can still leave the text
        // most of a pixel off a title on a fractional y (editor 46.0, title 46.74 at 1x). Measure where the editor
        // actually drew and move the field by whole pixels so the text lands within half a pixel of the title's.
        field.layoutSubtreeIfNeeded()
        guard let placed = Self.textOrigin(of: field) else { return }
        let landed = list.convert(placed, from: field)
        let dx = ((pen.x - landed.x) * scale).rounded() / scale, dy = ((pen.y - landed.y) * scale).rounded() / scale
        guard dx != 0 || dy != 0 else { return }
        frame.origin.x += dx
        frame.origin.y += dy
        frame.size.width = max(0, maxX - frame.minX)
        field.frame = frame
    }

    /// Where `field`'s editor draws its first glyph on its baseline, in the field's coordinates;
    /// nil when the field is not being edited.
    static func textOrigin(of field: NSTextField) -> NSPoint? {
        guard let editor = field.currentEditor() as? NSTextView else { return nil }
        let inset = editor.textContainerOrigin
        if let manager = editor.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
            guard let fragment = manager.textLayoutFragment(for: manager.documentRange.location),
                  let line = fragment.textLineFragments.first else { return nil }
            let frame = fragment.layoutFragmentFrame, bounds = line.typographicBounds
            let point = NSPoint(x: inset.x + frame.minX + bounds.minX + line.glyphOrigin.x,
                                y: inset.y + frame.minY + bounds.minY + line.glyphOrigin.y)
            return field.convert(point, from: editor)
        }
        guard let manager = editor.layoutManager, manager.numberOfGlyphs > 0 else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = manager.location(forGlyphAt: 0)
        return field.convert(NSPoint(x: inset.x + line.minX + glyph.x, y: inset.y + line.minY + glyph.y), from: editor)
    }

    /// `byKeyboard`: Return, Escape or Tab ended it (not a click elsewhere).
    func end(commit: Bool, byKeyboard: Bool = false) {
        groupMember = nil
        guard let session else { return }
        self.session = nil
        session.field.delegate = nil
        session.field.removeFromSuperview()
        list?.rowViews[session.key]?.setTitleHidden(false)
        let text = session.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list, commit, !session.cancelled, !text.isEmpty, text != session.original {
            switch session.key {
            case let .workspace(id): list.model.send(.rename(id, text))
            case let .group(id): list.model.send(.renameGroup(id, text))
            case .section, .emptySection, .emptyGroup, .folder, .item, .block, .doneFold, .showMore, .status: break
            }
            list.reload(animated: false)
        }
        list?.window?.makeFirstResponder(list)
        onEnded?(byKeyboard)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard session?.field === control else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            session?.cancelled = true
            end(commit: false, byKeyboard: true)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            end(commit: true, byKeyboard: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, session?.field === field else { return }
        // Tab and Backtab end editing from the keyboard; `other` is focus loss.
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        end(commit: true, byKeyboard: movement == .tab || movement == .backtab || movement == .return)
    }
}

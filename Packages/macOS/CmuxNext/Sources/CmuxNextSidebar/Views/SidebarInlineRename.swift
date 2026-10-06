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
        guard let group = group(containing: member) else { return }
        begin(.group(group))
        if session != nil { groupMember = member }
    }

    /// After a reload: moves a rename whose group the store replaced to
    /// the group its member is in now, keeping what was typed.
    func follow() {
        guard let member = groupMember, let current = session, case let .group(id) = current.key, list?.groups[id] == nil else { return }
        current.field.delegate = nil
        current.field.removeFromSuperview()
        session = nil
        guard let group = group(containing: member) else { return end(commit: false) }
        begin(.group(group))
        session?.field.stringValue = current.field.stringValue
        session?.original = current.original
        groupMember = member
    }

    private func group(containing member: WorkspaceID) -> GroupID? {
        list?.groups.values.first { $0.workspaces.contains { $0.id == member } }?.id
    }

    func begin(_ key: SidebarRowKey) {
        guard let list, list.model.presentation == .shown, list.drag == nil else { return }
        if session != nil { end(commit: true) }
        let original: String
        switch key {
        case let .workspace(id): original = list.workspaces[id]?.title ?? ""
        case let .group(id): original = list.groups[id]?.name ?? ""
        case .tab, .section, .emptySection: return
        }
        if let row = list.displayed.row(for: key) { list.scrollToVisible(list.frame(for: row)) }
        list.realizeVisibleRows()
        guard let view = list.rowViews[key] else { return }
        // The row's settled frame, not the view's: a row that just appeared (a group made by a drop) is still animating in.
        let rowFrame = list.displayed.row(for: key).map(list.frame(for:)) ?? view.frame
        let titleFrame = view.titleFrame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        // Follows theme changes while open (ThemedTextField).
        let field = ThemedTextField(string: original)
        // theme-scoped: ThemedTextField resolves its fill inside performWithTheme.
        field.fill = { Palette.hoverFill }
        field.font = view.titleFont
        field.isBordered = false
        field.drawsBackground = true
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
            width: max(0, view.frame.width - titleFrame.minX - Metrics.space3),
            height: height
        )
        list.addSubview(field)
        view.setTitleHidden(true)
        session = Session(key: key, field: field, original: original)
        list.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
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
            case .tab, .section, .emptySection: break
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

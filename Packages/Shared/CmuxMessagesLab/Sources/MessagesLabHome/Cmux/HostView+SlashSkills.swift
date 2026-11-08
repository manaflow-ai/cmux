// cmux: the Chief composer's `/` menu over the message box (ChatController+SlashSkills.swift).
// Not a vendored file.
import AppKit

extension HostView {
    /// Shows `menu` above the field (and above Reply to Selection's card when one shows); nil hides it.
    /// It appears and leaves in one frame: a menu that follows typing must never lag behind it.
    func showSlashMenu(_ menu: SlashSkillMenu?, onPick: @escaping (Int) -> Void, onHover: @escaping (Int) -> Void) {
        guard let menu else {
            slashMenuView?.removeFromSuperview()
            slashMenuView = nil
            return
        }
        let view = slashMenuView ?? SlashSkillMenuView(frame: .zero)
        if slashMenuView == nil {
            slashMenuView = view
            addSubview(view, positioned: .below, relativeTo: paneHeader)
        }
        view.onPick = onPick
        view.onHover = onHover
        view.show(menu)
        if let demo { placeSlashMenu(above: demo.compose.fieldRect) }
    }

    /// The menu sits just above the field (or the quote card), as wide as the field.
    func placeSlashMenu(above field: CGRect) {
        guard let view = slashMenuView, let menu = view.state, field.width > 0 else { return }
        let h = SlashSkillMenuView.height(for: menu)
        let top = quoteCard.map { $0.frame.minY } ?? field.minY
        let f = CGRect(x: field.minX, y: max(0, top - SlashSkillMenuView.gap - h), width: field.width, height: h).integral
        if view.frame != f { view.frame = f }
    }
}

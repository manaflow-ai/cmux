// cmux: `/` in a Chief chat's message box lists the Chief's skills, the person's Claude Code skills
// and their plugins' skills (Lawrence 2026-11-07: "i want to be able to invoke / skills from chief").
// Up and Down choose, Tab or Return picks (the field then holds `/name ` for the skill's input), a
// click picks, Esc closes it. The Chief host runs the skill when the message is sent
// (Native/OptChat/optchat-chief/src/slash_skills.rs). Not a vendored file.
import AppKit

extension ChatController {
    /// The field changed: the menu opens, follows the command or closes. One character test for a
    /// draft that does not start with `/` (this runs on every key typed into the box).
    func updateSlashMenu() {
        guard let source = slashSkills, let field = demo?.compose.textView.view,
              field.string.utf16.first == 0x2F, !field.hasMarkedText() else {
            slashMenuDismissed = nil
            if slashMenu != nil { slashMenu = nil }
            return
        }
        if slashMenuDismissed == field.string { return }
        slashMenuDismissed = nil
        // A fresh `/` reads the list again in the background (folders, or a paired server's host);
        // the menu shows the last list now. Typing more never asks again: a host that is down would
        // get one request per key.
        if field.string == "/" || !source.hasLoaded { source.refresh() }
        guard var menu = SlashSkillMenu(text: field.string, caret: field.selectedRange().location, skills: source.skills) else {
            if slashMenu != nil { slashMenu = nil }
            return
        }
        menu.isLoading = menu.matches.isEmpty && !source.hasLoaded
        menu.loadFailed = menu.matches.isEmpty && source.failed
        // The same command keeps its row (a list refresh); a new one starts at the best match.
        if let old = slashMenu, old.query == menu.query, let choice = old.choice, let i = menu.matches.firstIndex(of: choice) {
            menu.select(i)
        }
        guard menu != slashMenu else { return }
        slashMenu = menu
    }

    /// The field's commands while the menu shows: Up and Down choose, Tab picks, Esc closes.
    /// - Returns: True when the menu took the command.
    func handlesSlashCommand(_ selector: Selector) -> Bool {
        guard slashMenu != nil else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): slashMenu?.move(-1); return true
        case #selector(NSResponder.moveDown(_:)): slashMenu?.move(1); return true
        case #selector(NSResponder.insertTab(_:)): return pickSlashSkill()
        case #selector(NSResponder.cancelOperation(_:)): return dismissSlashMenu()
        default: return false
        }
    }

    /// Return while the menu shows: picks the selected skill, unless the command already names it
    /// (then Return sends, as it does without the menu).
    /// - Returns: True when the menu took the key.
    func slashMenuTakesReturn() -> Bool {
        guard let menu = slashMenu, menu.choice != nil, !menu.isComplete else { return false }
        return pickSlashSkill()
    }

    /// Esc while the menu shows closes it until the command changes.
    /// - Returns: True when a menu was open.
    @discardableResult
    func dismissSlashMenu() -> Bool {
        guard slashMenu != nil else { return false }
        slashMenuDismissed = demo?.compose.textView.view.string
        slashMenu = nil
        return true
    }

    /// Puts the selected (or `index`'s) skill's command in the field, the caret after its space.
    /// - Returns: True when a skill was picked.
    @discardableResult
    func pickSlashSkill(at index: Int? = nil) -> Bool {
        guard var menu = slashMenu, let field = demo?.compose.textView.view else { return false }
        if let index { menu.select(index) }
        guard let (text, caret) = menu.applied(to: field.string) else { return false }
        slashMenu = nil
        slashMenuDismissed = text
        field.replaceAllText(with: text)
        field.setSelectedRange(NSRange(location: caret, length: 0))
        focusCompose()
        return true
    }

    /// The menu view follows the state (`slashMenu`'s didSet).
    func slashMenuChanged() {
        host.showSlashMenu(slashMenu,
                           onPick: { [weak self] in self?.pickSlashSkill(at: $0) },
                           onHover: { [weak self] i in
                               guard var menu = self?.slashMenu else { return }
                               menu.select(i)
                               if menu != self?.slashMenu { self?.slashMenu = menu }
                           })
    }
}

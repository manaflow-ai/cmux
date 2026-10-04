import CmuxNextActions

extension PaletteModel {
    // MARK: Keyboard

    /// Applies a key command. Returns whether it was consumed; unconsumed
    /// commands fall through to the text field. Every command the key map
    /// produces is consumed, also when it has nothing to do (Return with no
    /// row, Backspace at the root): falling through, the field editor would
    /// end editing on Return or beep on a Backspace at the start, and the
    /// next key would reach `noResponder(for:)`, the system beep. Only
    /// Backspace with text in the field goes to the field.
    @discardableResult
    public func handle(_ command: PaletteKeyCommand) -> Bool {
        if actionsMenu != nil, handleActionsMenu(command) { return true }
        switch command {
        case .moveUp: send(.move(-1))
        case .moveDown: send(.move(1))
        case .pageUp: moveSelection(by: -Self.pageStep, wrap: false)
        case .pageDown: moveSelection(by: Self.pageStep, wrap: false)
        case .moveToFirst: selectRow(at: 0, scroll: true)
        case .moveToLast: selectRow(at: rows.count - 1, scroll: true)
        case .submit, .submitAlternate:
            // Rows of an older query wait for the current query's first
            // batch in the reducer, then run.
            runCommand = command
            send(.activate(nil))
        case .toggleActions:
            // Cmd-K on an action edits its shortcut; Tab keeps the Actions
            // menu (which lists Edit Keyboard Shortcut… too).
            if let id = selectedItem?.actionID, onEditShortcut?(id) == true { return true }
            _ = openActionsMenu()
        case .openActions:
            // Tab: a tree page enters the selected row; a keyword, a scope
            // row or a drill enters a scope; otherwise the Actions menu opens.
            if enterSelectedRow() { return true }
            send(.tab)
        case .closeActions:
            send(.shiftTab)
        case .escape where currentPageIsHierarchical && !query.isEmpty:
            // A tree page clears its query as typing would, so a typed path
            // returns to the folder it started from.
            query = ""
        case .escape:
            // A text step's text is the answer, not a search: Escape on a
            // prompt that a shortcut or menu opened cancels it at once
            // instead of clearing the text first.
            if isTextInput, let top = nav.top, !top.entry.isPushed, !query.isEmpty {
                send(.close)
                onDismiss?()
                return true
            }
            send(.escape)
        case .back:
            guard query.isEmpty else { return false }
            // A tree page goes up first; at its top Backspace pops it.
            if leaveLevel() { return true }
            send(.backspaceOnEmpty)
        case .enterRow:
            _ = enterSelectedRow()
        case .leaveLevel:
            _ = leaveLevel()
        case .closeItem:
            return handleCloseItem()
        case .actionsFilterAppend, .actionsFilterDeleteBackward:
            return false
        }
        return true
    }

    /// Cmd-W. With the selected row's close command: runs it, keeps the
    /// palette open, re-reads the page's providers (the row leaves once
    /// the owner's visible state drops it; nothing is hidden here) and
    /// selects the row after it in its section, else the one before. A
    /// page that owns the key (`PalettePageSpec.ownsCloseKey`) consumes it
    /// also without such a row. While a search is in flight it waits for
    /// that search, like Return.
    func handleCloseItem() -> Bool {
        let owns = currentPageOwnsCloseKey
        guard owns || selectedItem?.closeCommand != nil else { return false }
        actionsMenu = nil
        if searchTask != nil {
            pendingClose = true
            return true
        }
        if let item = selectedItem, item.closeCommand != nil, item.isEnabled { closeRow(item) }
        return true
    }

    func closeRow(_ item: PaletteItem) {
        guard item.isEnabled, let command = item.closeCommand, current != nil else { return }
        let placed = sections.flatMap { section in section.rows.map { (id: $0.id, section: section.section.id) } }
        guard performClose(command, rowID: item.id) else { return }
        if let next = Self.selection(afterRemoving: item.id, from: placed) { send(.select(next)) }
        reload()
    }

    /// The row to select after `removed` leaves `rows`: the next row of its
    /// section, else the previous row of its section, else none (repeated
    /// Cmd-W never walks from open tabs into another section).
    nonisolated public static func selection(afterRemoving removed: String, from rows: [(id: String, section: String)]) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == removed }) else { return nil }
        let section = rows[index].section
        if index + 1 < rows.count, rows[index + 1].section == section { return rows[index + 1].id }
        if index > 0, rows[index - 1].section == section { return rows[index - 1].id }
        return nil
    }

    func handleActionsMenu(_ command: PaletteKeyCommand) -> Bool {
        guard var menu = actionsMenu else { return false }
        let count = menu.visibleCommands.count
        switch command {
        case .moveUp, .moveDown:
            guard count > 0 else { return true }
            let delta = command == .moveUp ? -1 : 1
            menu.selectedIndex = (menu.selectedIndex + delta + count) % count
            actionsMenu = menu
        case .moveToFirst, .pageUp:
            menu.selectedIndex = 0
            actionsMenu = menu
        case .moveToLast, .pageDown:
            menu.selectedIndex = max(0, count - 1)
            actionsMenu = menu
        case .submit, .submitAlternate:
            let visible = menu.visibleCommands
            guard visible.indices.contains(menu.selectedIndex),
                  let item = rows.first(where: { $0.id == menu.itemID })?.item
            else { return true }
            let command = visible[menu.selectedIndex]
            actionsMenu = nil
            if let close = item.closeCommand, command.id == close.id, command.title == close.title, item.secondary.allSatisfy({ $0.id != close.id }) {
                closeRow(item)
            } else {
                run(command, of: item)
            }
        case .toggleActions, .closeActions, .escape:
            actionsMenu = nil
        case .openActions, .enterRow, .leaveLevel:
            break
        case .back:
            return false
        case .closeItem:
            return handleCloseItem()
        case .actionsFilterAppend(let text):
            menu.filter += text
            menu.selectedIndex = 0
            actionsMenu = menu
        case .actionsFilterDeleteBackward:
            if menu.filter.isEmpty {
                actionsMenu = nil
            } else {
                menu.filter.removeLast()
                menu.selectedIndex = 0
                actionsMenu = menu
            }
        }
        return true
    }

    func openActionsMenu() -> Bool {
        guard let item = selectedItem, item.isEnabled else { return false }
        actionsMenu = PaletteActionsMenuState(itemID: item.id, itemTitle: item.title, commands: item.allCommands)
        return true
    }

    /// Runs the command at `index` of the visible Actions menu (mouse).
    public func runActionsMenuCommand(at index: Int) {
        guard var menu = actionsMenu else { return }
        menu.selectedIndex = index
        actionsMenu = menu
        handle(.submit)
    }

    public func closeActionsMenu() {
        actionsMenu = nil
    }

    // MARK: Mouse

    public func hover(_ rowID: String?) {
        if hoveredRowID != rowID { hoveredRowID = rowID }
    }

    /// Click: select the row and run its primary command (or enter its
    /// scope).
    public func activate(rowID: String) {
        actionsMenu = nil
        runCommand = .submit
        send(.activate(rowID))
    }

    public func select(rowID: String) {
        guard rows.contains(where: { $0.id == rowID }) else { return }
        let scroll = scrollRequest
        send(.select(rowID))
        // A click selects without scrolling.
        scrollRequest = scroll
    }

    static let pageStep = 8

    func moveSelection(by delta: Int, wrap: Bool) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.id == selectedRowID } ?? -1
        var next = currentIndex + delta
        if wrap {
            next = ((next % rows.count) + rows.count) % rows.count
        } else {
            next = min(max(next, 0), rows.count - 1)
        }
        selectRow(at: next, scroll: true)
    }

    func selectRow(at index: Int, scroll: Bool) {
        let rows = self.rows
        guard rows.indices.contains(index) else { return }
        send(.select(rows[index].id))
        if scroll { scrollRequest += 1 }
    }
}

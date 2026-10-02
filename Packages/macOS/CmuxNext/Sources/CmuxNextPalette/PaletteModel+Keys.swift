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
        case .moveUp: moveSelection(by: -1, wrap: true)
        case .moveDown: moveSelection(by: 1, wrap: true)
        case .pageUp: moveSelection(by: -Self.pageStep, wrap: false)
        case .pageDown: moveSelection(by: Self.pageStep, wrap: false)
        case .moveToFirst: selectRow(at: 0, scroll: true)
        case .moveToLast: selectRow(at: rows.count - 1, scroll: true)
        case .submit, .submitAlternate:
            if searchTask != nil {
                // Rows on screen belong to an older query; run once the
                // current query's results land.
                pendingSubmit = command
                return true
            }
            guard let item = selectedItem else { return true }
            run(command == .submit ? item.primary : (item.alternate ?? item.primary), of: item)
        case .toggleActions:
            // Cmd-K on an action edits its shortcut; Tab keeps the Actions
            // menu (which lists Edit Keyboard Shortcut… too).
            if let id = selectedItem?.actionID, onEditShortcut?(id) == true { return true }
            _ = openActionsMenu()
        case .openActions:
            _ = openActionsMenu()
        case .closeActions:
            break
        case .escape:
            if pop() { return true }
            if !query.isEmpty {
                query = ""
                return true
            }
            onDismiss?()
        case .back:
            guard query.isEmpty else { return false }
            pop()
        case .closeItem:
            guard let item = selectedItem, item.closeCommand != nil else { return false }
            closeRow(item)
        case .actionsFilterAppend, .actionsFilterDeleteBackward:
            return false
        }
        return true
    }

    /// Runs `item`'s close command and keeps the palette open. Unless the
    /// command refused, the row leaves this page's list (the page's own
    /// view state: the owner's change reaches the source later) and the
    /// row after it, else the one before, is selected.
    func closeRow(_ item: PaletteItem) {
        guard item.isEnabled, let command = item.closeCommand, let state = current else { return }
        let ids = rows.map(\.id)
        guard performClose(command) else { return }
        if let next = Self.selection(afterRemoving: item.id, from: ids) {
            selectedRowID = next
            state.selectedRowID = next
        }
        state.removedItemIDs.insert(item.id)
        state.rebuild()
        refreshResults(resetSelection: false)
    }

    /// The row to select after `removed` leaves `rows`: the next one, else
    /// the previous one, else none.
    nonisolated public static func selection(afterRemoving removed: String, from rows: [String]) -> String? {
        guard let index = rows.firstIndex(of: removed) else { return nil }
        if index + 1 < rows.count { return rows[index + 1] }
        return index > 0 ? rows[index - 1] : nil
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
            if command.id == item.closeCommand?.id {
                closeRow(item)
            } else {
                run(command, of: item)
            }
        case .toggleActions, .closeActions, .escape:
            actionsMenu = nil
        case .openActions:
            break
        case .back, .closeItem:
            return false
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

    /// Click: select the row and run its primary command.
    public func activate(rowID: String) {
        selectedRowID = rowID
        actionsMenu = nil
        handle(.submit)
    }

    public func select(rowID: String) {
        guard rows.contains(where: { $0.id == rowID }) else { return }
        selectedRowID = rowID
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
        selectedRowID = rows[index].id
        current?.selectedRowID = selectedRowID
        if scroll { scrollRequest += 1 }
    }
}

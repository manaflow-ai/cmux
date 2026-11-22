// Catalog rows added with the tab, pane, column, screen, and terminal
// handlers (cmux-next only; no old-app inventory row). Titles live in
// LayoutActions.xcstrings (en, ja).

nonisolated enum LayoutActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        tabMoveActions() + paneExtraActions() + columnActions() + dockColumnActions() + terminalExtraActions()
    }

    static func row(
        _ id: ActionID, _ title: String, _ category: ActionCategory, _ symbol: String, cli: String,
        keywords: [String], targets: [ActionTargetKind], arguments: [ActionArgument] = [], startsTerminal: Bool = false,
        defaultShortcut: Shortcut? = nil
    ) -> ActionDescriptor {
        ActionDescriptor(
            id: id, title: title, keywords: keywords, defaultShortcut: defaultShortcut, category: category, symbol: symbol,
            surfaces: [.palette], arguments: arguments, targets: targets, cliName: cli, startsTerminal: startsTerminal
        )
    }

    private static func tabMoveActions() -> [ActionDescriptor] {
        [
            row("tab.moveToNewSplit", String(localized: "action.tab.moveToNewSplit", defaultValue: "Move Tab to New Split", table: "LayoutActions", bundle: .module),
                .tab, "rectangle.split.2x1", cli: "tab move-to-new-split", keywords: ["tab", "split", "pane"],
                targets: [.tab], arguments: [CatalogArgument.directionChoice.optional]),
            row("tab.moveToNewColumn", String(localized: "action.tab.moveToNewColumn", defaultValue: "Move Tab to New Column", table: "LayoutActions", bundle: .module),
                .tab, "rectangle.split.3x1", cli: "tab move-to-new-column", keywords: ["tab", "column"], targets: [.tab]),
            row("tab.moveToWorkspace", String(localized: "action.tab.moveToWorkspace", defaultValue: "Move Tab to Workspace…", table: "LayoutActions", bundle: .module),
                .tab, "arrow.right.square", cli: "tab move-to-workspace", keywords: ["tab", "workspace"],
                targets: [.tab], arguments: [CatalogArgument.workspaceWorkspace]),
            row("tab.moveToNewWindow", String(localized: "action.tab.moveToNewWindow", defaultValue: "Move Tab to New Window", table: "LayoutActions", bundle: .module),
                .tab, "macwindow.badge.plus", cli: "tab move-to-new-window", keywords: ["tab", "window", "detach"], targets: [.tab]),
            row("tabGroup.moveLeft", String(localized: "action.tabGroup.moveLeft", defaultValue: "Move Tab Group Left", table: "LayoutActions", bundle: .module),
                .tab, "arrow.left", cli: "tab-group move-left", keywords: ["group", "reorder"], targets: [.tabGroup]),
            row("tabGroup.moveRight", String(localized: "action.tabGroup.moveRight", defaultValue: "Move Tab Group Right", table: "LayoutActions", bundle: .module),
                .tab, "arrow.right", cli: "tab-group move-right", keywords: ["group", "reorder"], targets: [.tabGroup]),
        ]
    }

    private static func paneExtraActions() -> [ActionDescriptor] {
        [
            row("splitLeft", String(localized: "action.splitLeft", defaultValue: "Split Left", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.lefthalf.inset.filled", cli: "pane split-left", keywords: ["pane", "vertical"], targets: [.pane],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], startsTerminal: true),
            row("splitUp", String(localized: "action.splitUp", defaultValue: "Split Up", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.tophalf.inset.filled", cli: "pane split-up", keywords: ["pane", "horizontal"], targets: [.pane],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], startsTerminal: true),
            row("swapPaneLeft", String(localized: "action.swapPaneLeft", defaultValue: "Swap Pane Left", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.arrow.right", cli: "pane swap-left", keywords: ["pane", "move"], targets: [.pane]),
            row("swapPaneRight", String(localized: "action.swapPaneRight", defaultValue: "Swap Pane Right", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.arrow.right", cli: "pane swap-right", keywords: ["pane", "move"], targets: [.pane]),
            row("swapPaneUp", String(localized: "action.swapPaneUp", defaultValue: "Swap Pane Up", table: "LayoutActions", bundle: .module),
                .pane, "arrow.up.arrow.down", cli: "pane swap-up", keywords: ["pane", "move"], targets: [.pane]),
            row("swapPaneDown", String(localized: "action.swapPaneDown", defaultValue: "Swap Pane Down", table: "LayoutActions", bundle: .module),
                .pane, "arrow.up.arrow.down", cli: "pane swap-down", keywords: ["pane", "move"], targets: [.pane]),
            row("closePane", String(localized: "action.closePane", defaultValue: "Close Pane", table: "LayoutActions", bundle: .module),
                .pane, "xmark.rectangle", cli: "pane close", keywords: ["pane", "remove"], targets: [.pane]),
            // Chrome's Close Other Tabs for panes (cx-k9go): no question; each closed
            // pane's tabs go to the closed history and an undo toast offers them back.
            ActionDescriptor(
                id: "pane.closeOthers",
                title: String(localized: "action.pane.closeOthers", defaultValue: "Close Other Panes", table: "LayoutActions", bundle: .module),
                keywords: ["pane", "close", "others", "only"], category: .pane, symbol: "xmark.rectangle", surfaces: [.palette, .contextMenu],
                targets: [.pane], cliName: "pane close-others",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.pane, .close, 601)])
            ),
            row("renamePane", String(localized: "action.renamePane", defaultValue: "Rename Pane…", table: "LayoutActions", bundle: .module),
                .pane, "pencil", cli: "pane rename", keywords: ["pane", "title"], targets: [.pane],
                arguments: [CatalogArgument.nameString.optional]),
        ]
    }

    private static func columnActions() -> [ActionDescriptor] {
        let targets: [ActionTargetKind] = [.column, .pane]
        return [
            row("column.focusLeft", String(localized: "action.column.focusLeft", defaultValue: "Focus Column Left", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.to.line", cli: "column focus-left", keywords: ["column", "navigate"], targets: targets),
            row("column.focusRight", String(localized: "action.column.focusRight", defaultValue: "Focus Column Right", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.to.line", cli: "column focus-right", keywords: ["column", "navigate"], targets: targets),
            row("column.moveLeft", String(localized: "action.column.moveLeft", defaultValue: "Move Column Left", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.square", cli: "column move-left", keywords: ["column", "reorder"], targets: targets),
            row("column.moveRight", String(localized: "action.column.moveRight", defaultValue: "Move Column Right", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.square", cli: "column move-right", keywords: ["column", "reorder"], targets: targets),
            row("column.center", String(localized: "action.column.center", defaultValue: "Center Column", table: "LayoutActions", bundle: .module),
                .pane, "align.horizontal.center", cli: "column center", keywords: ["column", "scroll"], targets: targets),
            row("column.widthOneThird", String(localized: "action.column.widthOneThird", defaultValue: "Column Width: One Third", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.split.3x1", cli: "column width-one-third", keywords: ["column", "width", "preset"], targets: targets),
            row("column.widthHalf", String(localized: "action.column.widthHalf", defaultValue: "Column Width: Half", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.split.2x1", cli: "column width-half", keywords: ["column", "width", "preset"], targets: targets),
            row("column.widthTwoThirds", String(localized: "action.column.widthTwoThirds", defaultValue: "Column Width: Two Thirds", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.leadinghalf.inset.filled", cli: "column width-two-thirds", keywords: ["column", "width", "preset"], targets: targets),
            row("column.widthFull", String(localized: "action.column.widthFull", defaultValue: "Column Width: Full", table: "LayoutActions", bundle: .module),
                .pane, "rectangle", cli: "column width-full", keywords: ["column", "width", "maximize"], targets: targets),
            row("column.cycleWidth", String(localized: "action.column.cycleWidth", defaultValue: "Cycle Column Width", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.and.right", cli: "column cycle-width", keywords: ["column", "width", "preset"], targets: targets),
            row("column.cycleWidthBack", String(localized: "action.column.cycleWidthBack", defaultValue: "Cycle Column Width Backward", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.and.line.vertical.and.arrow.left", cli: "column cycle-width-back", keywords: ["column", "width"], targets: targets),
        ]
    }

    private static func terminalExtraActions() -> [ActionDescriptor] {
        [
            row("terminal.selectAll", String(localized: "action.terminal.selectAll", defaultValue: "Select All", table: "LayoutActions", bundle: .module),
                .terminal, "selection.pin.in.out", cli: "terminal select-all", keywords: ["select", "copy"], targets: [.tab]),
            // Decision K1: Cmd-K clears the focused terminal (Terminal.app, iTerm2 and Ghostty
            // `clear_screen`) and is no other default shortcut.
            ActionDescriptor(
                id: "terminal.clear",
                title: String(localized: "action.terminal.clear", defaultValue: "Clear Screen and Scrollback", table: "LayoutActions", bundle: .module),
                keywords: ["clear", "scrollback", "reset"], defaultShortcut: Shortcut("k", modifiers: [.command]), category: .terminal,
                symbol: "clear", surfaces: [.palette, .keyboard], requires: [.terminalFocused], targets: [.tab], cliName: "terminal clear"
            ),
            row("terminal.increaseFontSize", String(localized: "action.terminal.increaseFontSize", defaultValue: "Increase Font Size", table: "LayoutActions", bundle: .module),
                .terminal, "textformat.size.larger", cli: "terminal increase-font-size", keywords: ["font", "zoom", "bigger"], targets: [.tab]),
            row("terminal.decreaseFontSize", String(localized: "action.terminal.decreaseFontSize", defaultValue: "Decrease Font Size", table: "LayoutActions", bundle: .module),
                .terminal, "textformat.size.smaller", cli: "terminal decrease-font-size", keywords: ["font", "zoom", "smaller"], targets: [.tab]),
            row("terminal.resetFontSize", String(localized: "action.terminal.resetFontSize", defaultValue: "Reset Font Size", table: "LayoutActions", bundle: .module),
                .terminal, "textformat.size", cli: "terminal reset-font-size", keywords: ["font", "zoom", "default"], targets: [.tab]),
            row("terminal.sendText", String(localized: "action.terminal.sendText", defaultValue: "Send Text…", table: "LayoutActions", bundle: .module),
                .terminal, "text.cursor", cli: "terminal send-text", keywords: ["input", "type", "paste"], targets: [.tab],
                arguments: [CatalogArgument.textString]),
            row("terminal.scrollPageUp", String(localized: "action.terminal.scrollPageUp", defaultValue: "Scroll Page Up", table: "LayoutActions", bundle: .module),
                .terminal, "arrow.up.doc", cli: "terminal scroll-page-up", keywords: ["scroll", "scrollback"], targets: [.tab]),
            row("terminal.scrollPageDown", String(localized: "action.terminal.scrollPageDown", defaultValue: "Scroll Page Down", table: "LayoutActions", bundle: .module),
                .terminal, "arrow.down.doc", cli: "terminal scroll-page-down", keywords: ["scroll", "scrollback"], targets: [.tab]),
            row("terminal.scrollToTop", String(localized: "action.terminal.scrollToTop", defaultValue: "Scroll to Top", table: "LayoutActions", bundle: .module),
                .terminal, "arrow.up.to.line", cli: "terminal scroll-to-top", keywords: ["scroll", "scrollback", "start"], targets: [.tab]),
            row("terminal.scrollToBottom", String(localized: "action.terminal.scrollToBottom", defaultValue: "Scroll to Bottom", table: "LayoutActions", bundle: .module),
                .terminal, "arrow.down.to.line", cli: "terminal scroll-to-bottom", keywords: ["scroll", "scrollback", "end"], targets: [.tab]),
            // Ghostty's Cmd-J on macOS; Cmd-J J in cmux (`LeaderLayer`).
            row("terminal.scrollToSelection", String(localized: "action.terminal.scrollToSelection", defaultValue: "Scroll to Selection", table: "LayoutActions", bundle: .module),
                .terminal, "text.viewfinder", cli: "terminal scroll-to-selection", keywords: ["scroll", "scrollback", "selection", "jump"],
                targets: [.tab]),
        ]
    }
}

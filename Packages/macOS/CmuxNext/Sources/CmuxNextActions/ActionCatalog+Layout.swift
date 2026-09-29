// Catalog rows added with the tab, pane, column, screen, and terminal
// handlers (cmux-next only; no old-app inventory row). Titles live in
// LayoutActions.xcstrings (en, ja).

extension ActionCatalog {
    static func layoutActions() -> [ActionDescriptor] {
        tabMoveActions() + paneExtraActions() + columnActions() + screenActions() + terminalExtraActions()
    }

    private static func row(
        _ id: ActionID, _ title: String, _ category: ActionCategory, _ symbol: String, cli: String,
        keywords: [String], targets: [ActionTargetKind], arguments: [ActionArgument] = []
    ) -> ActionDescriptor {
        ActionDescriptor(
            id: id, title: title, keywords: keywords, category: category, symbol: symbol,
            surfaces: [.palette], arguments: arguments, targets: targets, cliName: cli
        )
    }

    private static func tabMoveActions() -> [ActionDescriptor] {
        [
            row("tab.moveToNewSplit", String(localized: "action.tab.moveToNewSplit", defaultValue: "Move Tab to New Split", table: "LayoutActions", bundle: .module),
                .tab, "rectangle.split.2x1", cli: "tab move-to-new-split", keywords: ["tab", "split", "pane"],
                targets: [.tab], arguments: [CatalogArgument.directionChoice.optional]),
            row("tab.moveToNewColumn", String(localized: "action.tab.moveToNewColumn", defaultValue: "Move Tab to New Column", table: "LayoutActions", bundle: .module),
                .tab, "rectangle.split.3x1", cli: "tab move-to-new-column", keywords: ["tab", "column", "niri"], targets: [.tab]),
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
                arguments: [CatalogArgument.cwdString.optional]),
            row("splitUp", String(localized: "action.splitUp", defaultValue: "Split Up", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.tophalf.inset.filled", cli: "pane split-up", keywords: ["pane", "horizontal"], targets: [.pane],
                arguments: [CatalogArgument.cwdString.optional]),
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
            row("renamePane", String(localized: "action.renamePane", defaultValue: "Rename Pane…", table: "LayoutActions", bundle: .module),
                .pane, "pencil", cli: "pane rename", keywords: ["pane", "title"], targets: [.pane],
                arguments: [CatalogArgument.nameString.optional]),
        ]
    }

    private static func columnActions() -> [ActionDescriptor] {
        let targets: [ActionTargetKind] = [.column, .pane]
        return [
            row("column.focusLeft", String(localized: "action.column.focusLeft", defaultValue: "Focus Column Left", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.to.line", cli: "column focus-left", keywords: ["column", "niri", "navigate"], targets: targets),
            row("column.focusRight", String(localized: "action.column.focusRight", defaultValue: "Focus Column Right", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.to.line", cli: "column focus-right", keywords: ["column", "niri", "navigate"], targets: targets),
            row("column.moveLeft", String(localized: "action.column.moveLeft", defaultValue: "Move Column Left", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.square", cli: "column move-left", keywords: ["column", "niri", "reorder"], targets: targets),
            row("column.moveRight", String(localized: "action.column.moveRight", defaultValue: "Move Column Right", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.square", cli: "column move-right", keywords: ["column", "niri", "reorder"], targets: targets),
            row("column.center", String(localized: "action.column.center", defaultValue: "Center Column", table: "LayoutActions", bundle: .module),
                .pane, "align.horizontal.center", cli: "column center", keywords: ["column", "niri", "scroll"], targets: targets),
            row("column.widthOneThird", String(localized: "action.column.widthOneThird", defaultValue: "Column Width: One Third", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.split.3x1", cli: "column width-one-third", keywords: ["column", "niri", "width", "preset"], targets: targets),
            row("column.widthHalf", String(localized: "action.column.widthHalf", defaultValue: "Column Width: Half", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.split.2x1", cli: "column width-half", keywords: ["column", "niri", "width", "preset"], targets: targets),
            row("column.widthTwoThirds", String(localized: "action.column.widthTwoThirds", defaultValue: "Column Width: Two Thirds", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.leadinghalf.inset.filled", cli: "column width-two-thirds", keywords: ["column", "niri", "width", "preset"], targets: targets),
            row("column.widthFull", String(localized: "action.column.widthFull", defaultValue: "Column Width: Full", table: "LayoutActions", bundle: .module),
                .pane, "rectangle", cli: "column width-full", keywords: ["column", "niri", "width", "maximize"], targets: targets),
            row("column.cycleWidth", String(localized: "action.column.cycleWidth", defaultValue: "Cycle Column Width", table: "LayoutActions", bundle: .module),
                .pane, "arrow.left.and.right", cli: "column cycle-width", keywords: ["column", "niri", "width", "preset"], targets: targets),
            row("column.cycleWidthBack", String(localized: "action.column.cycleWidthBack", defaultValue: "Cycle Column Width Backward", table: "LayoutActions", bundle: .module),
                .pane, "arrow.right.and.line.vertical.and.arrow.left", cli: "column cycle-width-back", keywords: ["column", "niri", "width"], targets: targets),
        ]
    }

    private static func screenActions() -> [ActionDescriptor] {
        [
            row("screen.new", String(localized: "action.screen.new", defaultValue: "New Screen", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.stack.badge.plus", cli: "screen new", keywords: ["screen", "tmux", "window", "create"], targets: [.screen]),
            row("screen.next", String(localized: "action.screen.next", defaultValue: "Next Screen", table: "LayoutActions", bundle: .module),
                .pane, "chevron.right.2", cli: "screen next", keywords: ["screen", "switch"], targets: [.screen]),
            row("screen.previous", String(localized: "action.screen.previous", defaultValue: "Previous Screen", table: "LayoutActions", bundle: .module),
                .pane, "chevron.left.2", cli: "screen previous", keywords: ["screen", "switch"], targets: [.screen]),
            row("screen.select", String(localized: "action.screen.select", defaultValue: "Select Screen 1…9", table: "LayoutActions", bundle: .module),
                .pane, "number.square", cli: "screen select", keywords: ["screen", "switch", "index"], targets: [.screen],
                arguments: [CatalogArgument.indexNumber]),
            row("screen.rename", String(localized: "action.screen.rename", defaultValue: "Rename Screen…", table: "LayoutActions", bundle: .module),
                .pane, "pencil", cli: "screen rename", keywords: ["screen", "title"], targets: [.screen],
                arguments: [CatalogArgument.nameString.optional]),
            row("screen.close", String(localized: "action.screen.close", defaultValue: "Close Screen", table: "LayoutActions", bundle: .module),
                .pane, "xmark.rectangle.portrait", cli: "screen close", keywords: ["screen", "remove"], targets: [.screen]),
            row("screen.toggleSwitcher", String(localized: "action.screen.toggleSwitcher", defaultValue: "Show/Hide Screen Switcher", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.3.group", cli: "screen toggle-switcher", keywords: ["screen", "switcher", "tabs"], targets: []),
        ]
    }

    private static func terminalExtraActions() -> [ActionDescriptor] {
        [
            row("terminal.selectAll", String(localized: "action.terminal.selectAll", defaultValue: "Select All", table: "LayoutActions", bundle: .module),
                .terminal, "selection.pin.in.out", cli: "terminal select-all", keywords: ["select", "copy"], targets: [.tab]),
            row("terminal.clear", String(localized: "action.terminal.clear", defaultValue: "Clear Screen and Scrollback", table: "LayoutActions", bundle: .module),
                .terminal, "clear", cli: "terminal clear", keywords: ["clear", "scrollback", "reset"], targets: [.tab]),
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
        ]
    }
}

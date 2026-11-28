// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum TerminalActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "toggleTerminalCopyMode",
                title: String(localized: "action.toggleTerminalCopyMode", defaultValue: "Toggle Copy Mode", bundle: .module),
                keywords: ["vi", "select", "scrollback"], defaultShortcut: Shortcut("m", modifiers: [.command, .shift]),
                category: .terminal, symbol: "character.cursor.ibeam", surfaces: [.palette, .keyboard],
                requires: [.terminalFocused], targets: [.pane], cliName: "terminal toggle-copy-mode"
            ),
            ActionDescriptor(
                id: "focusTextBoxInput",
                title: String(localized: "action.focusTextBoxInput", defaultValue: "Focus TextBox", bundle: .module),
                keywords: ["input", "compose"], defaultShortcut: Shortcut("a", modifiers: [.command, .option]),
                category: .terminal, symbol: "text.cursor", surfaces: [.palette, .keyboard],
                requires: [.terminalFocused], targets: [.pane], cliName: "terminal focus-textbox"
            ),
            ActionDescriptor(
                id: "palette.terminalToggleTextBoxInput",
                title: String(localized: "action.palette.terminalToggleTextBoxInput", defaultValue: "Toggle TextBox", bundle: .module),
                keywords: ["input", "compose"], category: .terminal, symbol: "rectangle.and.pencil.and.ellipsis",
                surfaces: [.palette], requires: [.terminalFocused], targets: [.pane], cliName: "terminal toggle-textbox"
            ),
            ActionDescriptor(
                id: "cycleTextBoxSubmitAction",
                title: String(localized: "action.cycleTextBoxSubmitAction", defaultValue: "Cycle TextBox Submit Action", bundle: .module),
                keywords: ["input", "compose"], defaultShortcut: Shortcut(Shortcut.tabKey, modifiers: [.shift]),
                category: .terminal, symbol: "arrow.triangle.swap", surfaces: [.keyboard], requires: [.textBoxFocused],
                targets: [.pane], cliName: "terminal cycle-textbox-submit-action"
            ),
            ActionDescriptor(
                id: "attachTextBoxFile",
                title: String(localized: "action.attachTextBoxFile", defaultValue: "Attach File to TextBox", bundle: .module),
                keywords: ["input", "attachment"],
                defaultShortcut: Shortcut("a", modifiers: [.shift, .option, .command]), category: .terminal,
                symbol: "paperclip", surfaces: [.palette, .keyboard], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal attach-file-to-textbox"
            ),
            ActionDescriptor(
                id: "sendCtrlFToTerminal",
                title: String(localized: "action.sendCtrlFToTerminal", defaultValue: "Send Ctrl-F to Terminal", bundle: .module),
                keywords: ["control", "key"], category: .terminal, symbol: "keyboard.badge.ellipsis",
                surfaces: [.palette, .keyboard, .menu], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal send-ctrl-f-to", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "pasteLastScreenshot",
                title: String(localized: "action.pasteLastScreenshot", defaultValue: "Paste Last Screenshot", bundle: .module),
                keywords: ["image", "paste"], category: .terminal, symbol: "photo.on.rectangle",
                surfaces: [.palette, .keyboard], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal paste-last-screenshot"
            ),
            ActionDescriptor(
                id: "terminal.keep",
                title: String(localized: "action.terminal.keep", defaultValue: "Keep Terminal Running After Close", bundle: .module),
                keywords: ["keep", "detach", "background", "reap"], category: .terminal, symbol: "pin",
                surfaces: [.palette], arguments: [CatalogArgument.onBool.optional], targets: [.tab],
                cliName: "terminal keep"
            ),
            ActionDescriptor(
                id: "clearScreenKeepScrollback",
                title: String(localized: "action.clearScreenKeepScrollback", defaultValue: "Clear Screen (Keep Scrollback)", bundle: .module),
                keywords: ["clear", "reset"], defaultShortcut: Shortcut("k", modifiers: [.command, .shift]),
                category: .terminal, symbol: "clear", surfaces: [.palette, .keyboard], requires: [.terminalFocused],
                targets: [.pane], cliName: "terminal clear-screen-keep-scrollback"
            ),
            ActionDescriptor(
                id: "find", title: String(localized: "action.find", defaultValue: "Find…", bundle: .module),
                keywords: ["search"], defaultShortcut: Shortcut("f", modifiers: [.command]), category: .terminal,
                symbol: "magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.textString.optional], targets: [.pane],
                cliName: "terminal find", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "findInDirectory",
                title: String(localized: "action.findInDirectory", defaultValue: "Find in Directory…", bundle: .module),
                keywords: ["search", "grep"], defaultShortcut: Shortcut("f", modifiers: [.command, .shift]),
                category: .terminal, symbol: "folder.badge.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.textString], targets: [.pane],
                cliName: "terminal find-in-directory", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "findNext", title: String(localized: "action.findNext", defaultValue: "Find Next", bundle: .module),
                keywords: ["search"], defaultShortcut: Shortcut("g", modifiers: [.command]), category: .terminal,
                symbol: "chevron.down.circle", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "terminal find-next", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "findPrevious",
                title: String(localized: "action.findPrevious", defaultValue: "Find Previous", bundle: .module),
                keywords: ["search"], defaultShortcut: Shortcut("g", modifiers: [.option, .command]),
                category: .terminal, symbol: "chevron.up.circle", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "terminal find-previous", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "hideFind",
                title: String(localized: "action.hideFind", defaultValue: "Hide Find Bar", bundle: .module),
                keywords: ["search", "close"], defaultShortcut: Shortcut("f", modifiers: [.shift, .option, .command]),
                category: .terminal, symbol: "xmark.circle", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "terminal hide-find-bar", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "useSelectionForFind",
                title: String(localized: "action.useSelectionForFind", defaultValue: "Use Selection for Find", bundle: .module),
                keywords: ["search", "selection"], defaultShortcut: Shortcut("e", modifiers: [.command]),
                category: .terminal, symbol: "text.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "terminal use-selection-for-find", mainMenu: .edit
            ),
            ActionDescriptor(
                id: "terminalCopy",
                title: String(localized: "action.terminalCopy", defaultValue: "Copy", bundle: .module),
                keywords: ["clipboard"], defaultShortcut: Shortcut("c", modifiers: [.command]), category: .terminal,
                symbol: "doc.on.doc", surfaces: [.contextMenu], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal copy"
            ),
            ActionDescriptor(
                id: "terminalPaste",
                title: String(localized: "action.terminalPaste", defaultValue: "Paste", bundle: .module),
                keywords: ["clipboard"], defaultShortcut: Shortcut("v", modifiers: [.command]), category: .terminal,
                symbol: "doc.on.clipboard", surfaces: [.contextMenu], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal paste"
            ),
            ActionDescriptor(
                id: "resetTerminal",
                title: String(localized: "action.resetTerminal", defaultValue: "Reset Terminal", bundle: .module),
                keywords: ["clear", "reset"], category: .terminal, symbol: "arrow.counterclockwise",
                surfaces: [.contextMenu], requires: [.terminalFocused], targets: [.pane], cliName: "terminal reset"
            ),
            ActionDescriptor(
                id: "reconnectPane",
                title: String(localized: "action.reconnectPane", defaultValue: "Reconnect Pane", bundle: .module),
                keywords: ["reconnect", "daemon"], category: .terminal, symbol: "arrow.triangle.2.circlepath.circle",
                surfaces: [.contextMenu], requires: [.terminalFocused], targets: [.pane],
                cliName: "terminal reconnect-pane"
            ),
            ActionDescriptor(
                id: "resumeCommandSet",
                title: String(localized: "action.resumeCommandSet", defaultValue: "Set Resume Command…", bundle: .module),
                keywords: ["resume", "fork"], category: .terminal, symbol: "play.circle", surfaces: [.contextMenu],
                requires: [.terminalFocused], arguments: [CatalogArgument.commandString], targets: [.pane],
                cliName: "terminal set-resume-command"
            ),
            ActionDescriptor(
                id: "resumeCommandEdit",
                title: String(localized: "action.resumeCommandEdit", defaultValue: "Edit Resume Command…", bundle: .module),
                keywords: ["resume", "fork"], category: .terminal, symbol: "play.square", surfaces: [.contextMenu],
                requires: [.terminalFocused], arguments: [CatalogArgument.commandString], targets: [.pane],
                cliName: "terminal edit-resume-command"
            ),
            ActionDescriptor(
                id: "resumeCommandClear",
                title: String(localized: "action.resumeCommandClear", defaultValue: "Clear Resume Command", bundle: .module),
                keywords: ["resume", "fork"], category: .terminal, symbol: "stop.circle", surfaces: [.contextMenu],
                requires: [.terminalFocused], targets: [.pane], cliName: "terminal clear-resume-command"
            ),
            ActionDescriptor(
                id: "palette.terminalOpenDirectory",
                title: String(localized: "action.palette.terminalOpenDirectory", defaultValue: "Open Current Directory in…", bundle: .module),
                keywords: ["finder", "editor", "open in"], category: .terminal, symbol: "arrow.up.forward.app",
                surfaces: [.palette], arguments: [CatalogArgument.appString], targets: [.pane],
                cliName: "terminal open-current-directory-in"
            ),
        ]
    }
}

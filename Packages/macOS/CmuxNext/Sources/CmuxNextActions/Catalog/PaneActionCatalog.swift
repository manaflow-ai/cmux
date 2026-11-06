// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum PaneActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "splitRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.splitRight") + "\u{E002}" + String(localized: "action.splitRight", defaultValue: "Split Right", bundle: .module)),
                keywords: ["pane", "vertical"], defaultShortcut: Shortcut("d", modifiers: [.command]), category: .pane,
                symbol: "rectangle.split.2x1", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], targets: [.pane], cliName: "pane split-right", mainMenu: .view, startsTerminal: true
            ),
            // A PNG of the pane as on screen, never changing focus or selection
            // (ScreenshotHandlers): Copy menu, palette and automation. An agent's or a
            // script's capture comes back with every browser page and agent chat masked.
            ActionDescriptor(
                id: "pane.screenshot",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.pane.screenshot") + "\u{E002}" + String(localized: "action.pane.screenshot", defaultValue: "Screenshot Pane", bundle: .module)),
                keywords: ["screenshot", "capture", "image", "png", "picture"], category: .pane, symbol: "camera",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.screenshotOut], targets: [.pane],
                cliName: "pane screenshot",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.pane, .inspect, 510, folder: .copy)])
            ),
            // New Column Right keeps the `newColumn` id (cmux.json bindings, scripts); New Column
            // Left opens before the pane's column (`column-left-v1`). Both search as "new column".
            // New Column Ctrl-Cmd-X and New Row Ctrl-Shift-Cmd-X: X is the second D: Ctrl adds a column / row,
            // Option a browser, Shift means below (PaneCreateKeySetTests). Not Ctrl-Cmd-D: macOS's Look Up (system
            // hot key 70, on by default) takes it before cmux (MacOSSystemShortcutsTests).
            ActionDescriptor(
                id: "newColumn",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newColumn") + "\u{E002}" + String(localized: "action.newColumn", defaultValue: "New Column Right", bundle: .module)),
                keywords: ["new column", "scroll", "column", "pane", "right", "add"],
                defaultShortcut: Shortcut("x", modifiers: [.control, .command]), category: .pane,
                symbol: "rectangle.split.3x1", surfaces: [.palette, .keyboard, .menu, .contextMenu], targets: [.pane],
                cliName: "pane new-column", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newColumnLeft",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newColumnLeft") + "\u{E002}" + String(localized: "action.newColumnLeft", defaultValue: "New Column Left", bundle: .module)),
                keywords: ["new column", "scroll", "column", "pane", "left", "add", "before"],
                category: .pane, symbol: "rectangle.lefthalf.inset.filled", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.pane], cliName: "pane new-column-left", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newRow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newRow") + "\u{E002}" + String(localized: "action.newRow", defaultValue: "New Row", bundle: .module)),
                keywords: ["scroll", "row", "pane"],
                defaultShortcut: Shortcut("x", modifiers: [.control, .shift, .command]), category: .pane,
                symbol: "rectangle.grid.1x2", surfaces: [.palette, .keyboard, .menu, .contextMenu], targets: [.pane],
                cliName: "pane new-row", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "splitDown",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.splitDown") + "\u{E002}" + String(localized: "action.splitDown", defaultValue: "Split Down", bundle: .module)),
                keywords: ["pane", "horizontal"], defaultShortcut: Shortcut("d", modifiers: [.command, .shift]),
                category: .pane, symbol: "rectangle.split.1x2", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], targets: [.pane], cliName: "pane split-down", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newPaneAutoLayout",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newPaneAutoLayout") + "\u{E002}" + String(localized: "action.newPaneAutoLayout", defaultValue: "New Pane (Auto Layout)", bundle: .module)),
                // Zellij's new pane: the largest scrolling pane splits along its longer side.
                keywords: ["split", "pane", "smart arrange", "auto arrange", "tile", "zellij"], defaultShortcut: Shortcut("n", modifiers: [.control, .command]),
                category: .pane, symbol: "rectangle.badge.plus", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "pane new-auto-layout", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "toggleSplitZoom",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleSplitZoom") + "\u{E002}" + String(localized: "action.toggleSplitZoom", defaultValue: "Toggle Pane Zoom", bundle: .module)),
                keywords: ["maximize", "zoom"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command, .shift]), category: .pane,
                symbol: "arrow.up.left.and.down.right.magnifyingglass", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.pane], cliName: "pane toggle-zoom"
            ),
            // Show Tab Bar (cx-soza): the pane's own choice; the palette and menu read Hide Tab Bar while shown.
            ActionDescriptor(
                id: "pane.toggleTabBar",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.pane.toggleTabBar") + "\u{E002}" + String(localized: "action.pane.toggleTabBar", defaultValue: "Show Tab Bar", bundle: .module)),
                keywords: ["tab bar", "tabs", "strip", "horizontal", "hide", "show", "pane"],
                category: .pane, symbol: "menubar.rectangle", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.pane], cliName: "pane toggle-tab-bar"
            ),
            ActionDescriptor(
                id: "equalizeSplits",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.equalizeSplits") + "\u{E002}" + String(localized: "action.equalizeSplits", defaultValue: "Equalize Splits", bundle: .module)),
                // Ctrl-Cmd-= as Ghostty's `equalize_splits` (Lawrence 2026-10-19); the interface scale moved to Ctrl-Shift-Cmd.
                keywords: ["balance", "resize"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .command]), category: .pane,
                symbol: "equal.square", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane equalize-splits", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneLeft",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.resizePaneLeft") + "\u{E002}" + String(localized: "action.resizePaneLeft", defaultValue: "Resize Pane Left", bundle: .module)),
                keywords: ["resize"], defaultShortcut: Shortcut("h", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.left.to.line", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-left", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.resizePaneRight") + "\u{E002}" + String(localized: "action.resizePaneRight", defaultValue: "Resize Pane Right", bundle: .module)),
                keywords: ["resize"], defaultShortcut: Shortcut("l", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.right.to.line", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneUp",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.resizePaneUp") + "\u{E002}" + String(localized: "action.resizePaneUp", defaultValue: "Resize Pane Up", bundle: .module)),
                keywords: ["resize"], defaultShortcut: Shortcut("k", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.up.to.line.compact", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-up", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneDown",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.resizePaneDown") + "\u{E002}" + String(localized: "action.resizePaneDown", defaultValue: "Resize Pane Down", bundle: .module)),
                keywords: ["resize"], defaultShortcut: Shortcut("j", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.down.to.line.compact", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-down", mainMenu: .view
            ),
            ActionDescriptor(
                id: "focusLeft",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusLeft") + "\u{E002}" + String(localized: "action.focusLeft", defaultValue: "Focus Pane Left", bundle: .module)),
                keywords: ["navigate"],
                // Ghostty's goto_split:left, reserved (schemas/keybindings/ghostty-reserved-keys.json).
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.left.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-left"
            ),
            ActionDescriptor(
                id: "focusRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusRight") + "\u{E002}" + String(localized: "action.focusRight", defaultValue: "Focus Pane Right", bundle: .module)),
                keywords: ["navigate"],
                // Ghostty's goto_split:right, reserved (schemas/keybindings/ghostty-reserved-keys.json).
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.right.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-right"
            ),
            ActionDescriptor(
                id: "focusUp",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusUp") + "\u{E002}" + String(localized: "action.focusUp", defaultValue: "Focus Pane Above", bundle: .module)),
                keywords: ["navigate"], defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.option, .command]),
                category: .pane, symbol: "arrow.up.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-above"
            ),
            ActionDescriptor(
                id: "focusDown",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusDown") + "\u{E002}" + String(localized: "action.focusDown", defaultValue: "Focus Pane Below", bundle: .module)),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.down.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-below"
            ),
            ActionDescriptor(
                id: "focusPreviousPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusPreviousPane") + "\u{E002}" + String(localized: "action.focusPreviousPane", defaultValue: "Focus Previous Pane", bundle: .module)),
                keywords: ["navigate"], category: .pane, symbol: "arrow.backward.square",
                surfaces: [.palette, .keyboard], targets: [.pane], cliName: "pane focus-previous"
            ),
            ActionDescriptor(
                id: "focusNextPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusNextPane") + "\u{E002}" + String(localized: "action.focusNextPane", defaultValue: "Focus Next Pane", bundle: .module)),
                keywords: ["navigate"], category: .pane, symbol: "arrow.forward.square",
                surfaces: [.palette, .keyboard], targets: [.pane], cliName: "pane focus-next"
            ),
            // Ctrl-Cmd-1..9 (cx-zjtn.2): the screen's panes in Focus Next
            // Pane order; 9 is the last pane.
            ActionDescriptor(
                id: "focusPaneByNumber",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusPaneByNumber") + "\u{E002}" + String(localized: "action.focusPaneByNumber", defaultValue: "Focus Pane 1…9", bundle: .module)),
                keywords: ["pane", "jump", "number", "index", "navigate"], defaultShortcut: Shortcut("1", modifiers: [.control, .command]),
                shortcutFamily: .digits, category: .pane, symbol: "number.square", surfaces: [.keyboard],
                arguments: [CatalogArgument.indexNumber], targets: [.pane], cliName: "pane focus-1-9"
            ),
            ActionDescriptor(
                id: "triggerFlash",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.triggerFlash") + "\u{E002}" + String(localized: "action.triggerFlash", defaultValue: "Flash Focused Pane", bundle: .module)),
                keywords: ["highlight", "locate"], defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane, symbol: "bolt", surfaces: [.palette, .keyboard, .contextMenu], targets: [.pane],
                cliName: "pane flash-focused"
            ),
            ActionDescriptor(
                id: "palette.swapWithSession",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.swapWithSession") + "\u{E002}" + String(localized: "action.palette.swapWithSession", defaultValue: "Swap with Session…", bundle: .module)),
                keywords: ["swap", "exchange"], category: .pane, symbol: "arrow.left.arrow.right",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.panePane], targets: [.pane],
                cliName: "pane swap-with-session"
            ),
            ActionDescriptor(
                id: "increaseWorkspaceTerminalFontSize",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.increaseWorkspaceTerminalFontSize") + "\u{E002}" + String(localized: "action.increaseWorkspaceTerminalFontSize", defaultValue: "Increase Workspace Font Size", bundle: .module)),
                keywords: ["zoom", "bigger"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .pane, symbol: "textformat.size.larger", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane increase-workspace-font-size"
            ),
            ActionDescriptor(
                id: "decreaseWorkspaceTerminalFontSize",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.decreaseWorkspaceTerminalFontSize") + "\u{E002}" + String(localized: "action.decreaseWorkspaceTerminalFontSize", defaultValue: "Decrease Workspace Font Size", bundle: .module)),
                keywords: ["zoom", "smaller"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .pane, symbol: "textformat.size.smaller", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane decrease-workspace-font-size"
            ),
            ActionDescriptor(
                id: "resetWorkspaceTerminalFontSize",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.resetWorkspaceTerminalFontSize") + "\u{E002}" + String(localized: "action.resetWorkspaceTerminalFontSize", defaultValue: "Reset Workspace Font Size", bundle: .module)),
                keywords: ["zoom", "default"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .pane, symbol: "textformat.size", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane reset-workspace-font-size"
            ),
            ActionDescriptor(
                id: "toggleCanvasLayout",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleCanvasLayout") + "\u{E002}" + String(localized: "action.toggleCanvasLayout", defaultValue: "Toggle Canvas Layout", bundle: .module)),
                keywords: ["canvas", "freeform"], defaultShortcut: Shortcut("c", modifiers: [.control, .command]),
                category: .pane, symbol: "rectangle.3.group", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane toggle-canvas-layout", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasOverview",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasOverview") + "\u{E002}" + String(localized: "action.canvasOverview", defaultValue: "Canvas Overview", bundle: .module)),
                keywords: ["canvas", "expose"], defaultShortcut: Shortcut("o", modifiers: [.control, .command]),
                category: .pane, symbol: "square.grid.3x3", surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-overview", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasTidy",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasTidy") + "\u{E002}" + String(localized: "action.canvasTidy", defaultValue: "Tidy Canvas", bundle: .module)),
                keywords: ["canvas", "arrange"], defaultShortcut: Shortcut("t", modifiers: [.control, .command]),
                category: .pane, symbol: "square.grid.2x2.fill", surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane tidy-canvas", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasRevealFocusedPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasRevealFocusedPane") + "\u{E002}" + String(localized: "action.canvasRevealFocusedPane", defaultValue: "Reveal Focused Pane on Canvas", bundle: .module)),
                keywords: ["canvas", "center"], defaultShortcut: Shortcut("r", modifiers: [.control, .command]),
                category: .pane, symbol: "scope", surfaces: [.palette, .keyboard, .menu], requires: [.canvasLayout],
                targets: [.pane], cliName: "pane reveal-focused-on-canvas", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasZoomIn",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasZoomIn") + "\u{E002}" + String(localized: "action.canvasZoomIn", defaultValue: "Canvas Zoom In", bundle: .module)),
                keywords: ["canvas", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.option, .command]),
                category: .pane, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-zoom-in"
            ),
            ActionDescriptor(
                id: "canvasZoomOut",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasZoomOut") + "\u{E002}" + String(localized: "action.canvasZoomOut", defaultValue: "Canvas Zoom Out", bundle: .module)),
                keywords: ["canvas", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.option, .command]),
                category: .pane, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-zoom-out"
            ),
            ActionDescriptor(
                id: "canvasZoomReset",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasZoomReset") + "\u{E002}" + String(localized: "action.canvasZoomReset", defaultValue: "Canvas Actual Size", bundle: .module)),
                keywords: ["canvas", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .pane, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-actual-size"
            ),
            ActionDescriptor(
                id: "canvasAlignLeft",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasAlignLeft") + "\u{E002}" + String(localized: "action.canvasAlignLeft", defaultValue: "Align Panes Left", bundle: .module)),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.horizontal.left",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane], cliName: "pane align-left"
            ),
            ActionDescriptor(
                id: "canvasAlignRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasAlignRight") + "\u{E002}" + String(localized: "action.canvasAlignRight", defaultValue: "Align Panes Right", bundle: .module)),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.horizontal.right",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane align-right"
            ),
            ActionDescriptor(
                id: "canvasAlignTop",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasAlignTop") + "\u{E002}" + String(localized: "action.canvasAlignTop", defaultValue: "Align Panes Top", bundle: .module)),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.vertical.top",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane], cliName: "pane align-top"
            ),
            ActionDescriptor(
                id: "canvasAlignBottom",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasAlignBottom") + "\u{E002}" + String(localized: "action.canvasAlignBottom", defaultValue: "Align Panes Bottom", bundle: .module)),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.vertical.bottom",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane align-bottom"
            ),
            ActionDescriptor(
                id: "canvasEqualizeWidths",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasEqualizeWidths") + "\u{E002}" + String(localized: "action.canvasEqualizeWidths", defaultValue: "Equalize Pane Widths", bundle: .module)),
                keywords: ["canvas", "equalize"], category: .pane, symbol: "arrow.left.and.right.square",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane equalize-widths"
            ),
            ActionDescriptor(
                id: "canvasEqualizeHeights",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasEqualizeHeights") + "\u{E002}" + String(localized: "action.canvasEqualizeHeights", defaultValue: "Equalize Pane Heights", bundle: .module)),
                keywords: ["canvas", "equalize"], category: .pane, symbol: "arrow.up.and.down.square",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane equalize-heights"
            ),
            ActionDescriptor(
                id: "canvasDistributeHorizontally",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasDistributeHorizontally") + "\u{E002}" + String(localized: "action.canvasDistributeHorizontally", defaultValue: "Distribute Panes Horizontally", bundle: .module)),
                keywords: ["canvas", "distribute"], category: .pane, symbol: "distribute.horizontal.center",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane distribute-horizontally"
            ),
            ActionDescriptor(
                id: "canvasDistributeVertically",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.canvasDistributeVertically") + "\u{E002}" + String(localized: "action.canvasDistributeVertically", defaultValue: "Distribute Panes Vertically", bundle: .module)),
                keywords: ["canvas", "distribute"], category: .pane, symbol: "distribute.vertical.center",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane distribute-vertically"
            ),
            ActionDescriptor(
                id: "palette.newSimulatorPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.newSimulatorPane") + "\u{E002}" + String(localized: "action.palette.newSimulatorPane", defaultValue: "New Simulator Pane", bundle: .module)),
                keywords: ["ios", "simulator", "xcode"], category: .pane, symbol: "iphone", surfaces: [.palette, .menu],
                targets: [.pane], cliName: "pane new-simulator", mainMenu: .view
            ),
            ActionDescriptor(
                id: "simulatorHome",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.simulatorHome") + "\u{E002}" + String(localized: "action.simulatorHome", defaultValue: "Simulator: Home", bundle: .module)),
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane, symbol: "house", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-home"
            ),
            ActionDescriptor(
                id: "simulatorRotateLeft",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.simulatorRotateLeft") + "\u{E002}" + String(localized: "action.simulatorRotateLeft", defaultValue: "Simulator: Rotate Left", bundle: .module)),
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.command]),
                category: .pane, symbol: "rotate.left", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-rotate-left"
            ),
            ActionDescriptor(
                id: "simulatorRotateRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.simulatorRotateRight") + "\u{E002}" + String(localized: "action.simulatorRotateRight", defaultValue: "Simulator: Rotate Right", bundle: .module)),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.command]), category: .pane,
                symbol: "rotate.right", surfaces: [.keyboard], requires: [.simulatorFocused], targets: [.pane],
                cliName: "pane simulator-rotate-right"
            ),
            ActionDescriptor(
                id: "simulatorToggleAppearance",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.simulatorToggleAppearance") + "\u{E002}" + String(localized: "action.simulatorToggleAppearance", defaultValue: "Simulator: Toggle Appearance", bundle: .module)),
                keywords: ["ios", "simulator", "dark mode"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .shift]), category: .pane,
                symbol: "circle.lefthalf.filled.inverse", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-toggle-appearance"
            ),
            ActionDescriptor(
                id: "simulatorToggleSoftwareKeyboard",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.simulatorToggleSoftwareKeyboard") + "\u{E002}" + String(localized: "action.simulatorToggleSoftwareKeyboard", defaultValue: "Simulator: Toggle Software Keyboard", bundle: .module)),
                // Decision K1: Cmd-K is Clear Screen and Scrollback only (Simulator.app uses Cmd-K here).
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut("k", modifiers: [.command, .shift]), category: .pane,
                symbol: "keyboard", surfaces: [.keyboard], requires: [.simulatorFocused], targets: [.pane],
                cliName: "pane simulator-toggle-software-keyboard"
            ),
            ActionDescriptor(
                id: "palette.openFilesPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.openFilesPane") + "\u{E002}" + String(localized: "action.palette.openFilesPane", defaultValue: "Open Files as Pane", bundle: .module)),
                keywords: ["explorer", "pane"], category: .pane, symbol: "doc.text", surfaces: [.palette],
                arguments: [CatalogArgument.optionalPathString], targets: [.pane], cliName: "pane open-files-as"
            ),
            ActionDescriptor(
                id: "palette.openFindPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.openFindPane") + "\u{E002}" + String(localized: "action.palette.openFindPane", defaultValue: "Open Find as Pane", bundle: .module)),
                keywords: ["search", "pane"], category: .pane, symbol: "text.magnifyingglass", surfaces: [.palette],
                arguments: [CatalogArgument.optionalPathString], targets: [.pane], cliName: "pane open-find-as"
            ),
            ActionDescriptor(
                id: "palette.openVaultPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.openVaultPane") + "\u{E002}" + String(localized: "action.palette.openVaultPane", defaultValue: "Open Vault as Pane", bundle: .module)),
                keywords: ["sessions", "pane"], category: .pane, symbol: "archivebox", surfaces: [.palette],
                targets: [.pane], cliName: "pane open-vault-as"
            ),
            ActionDescriptor(
                id: "palette.openCloudPane",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.openCloudPane") + "\u{E002}" + String(localized: "action.palette.openCloudPane", defaultValue: "Open Cloud as Pane", bundle: .module)),
                keywords: ["machines", "pane", "vm", "snapshots", "cloud"], category: .pane, symbol: "cloud",
                surfaces: [.palette, .menu], targets: [.pane], cliName: "pane open-cloud-as", mainMenu: .window,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "artifacts.show",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.artifacts.show") + "\u{E002}" + String(localized: "action.artifacts.show", defaultValue: "Show Artifacts", bundle: .module)),
                keywords: ["artifacts", "memory", "memories", "notes", "history", "saved"], category: .pane, symbol: "shippingbox",
                surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // A file in a tab of the pane or in the text editor: the agent pane's changed
            // files (#16723), the palette and the File menu (no path: the cmux
            // picker at the pane's folder, R89), and `cmux file open`. `asText` (`--as-text`):
            // HTML, SVG or Markdown opens as its source in the code editor (u18462).
            ActionDescriptor(
                id: "file.open",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.file.open") + "\u{E002}" + String(localized: "action.file.open", defaultValue: "Open File…", bundle: .module)),
                keywords: ["file", "editor", "preview", "path"], category: .pane, symbol: "doc",
                surfaces: [.palette, .menu], arguments: [CatalogArgument.optionalPathString, CatalogArgument.whereChoice, CatalogArgument.asTextBool],
                targets: [.pane], cliName: "file open", mainMenu: .file
            ),
        ]
    }
}

// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func paneActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "splitRight",
                title: String(localized: "action.splitRight", defaultValue: "Split Right", bundle: .module),
                keywords: ["pane", "vertical"], defaultShortcut: Shortcut("d", modifiers: [.command]), category: .pane,
                symbol: "rectangle.split.2x1", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], targets: [.pane], cliName: "pane split-right", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newColumn",
                title: String(localized: "action.newColumn", defaultValue: "New Column", bundle: .module),
                keywords: ["niri", "scroll", "column", "pane"],
                defaultShortcut: Shortcut("n", modifiers: [.shift, .option, .command]), category: .pane,
                symbol: "rectangle.split.3x1", surfaces: [.palette, .keyboard, .menu, .contextMenu], targets: [.pane],
                cliName: "pane new-column", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "splitDown",
                title: String(localized: "action.splitDown", defaultValue: "Split Down", bundle: .module),
                keywords: ["pane", "horizontal"], defaultShortcut: Shortcut("d", modifiers: [.command, .shift]),
                category: .pane, symbol: "rectangle.split.1x2", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], targets: [.pane], cliName: "pane split-down", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newPaneAutoLayout",
                title: String(localized: "action.newPaneAutoLayout", defaultValue: "New Pane (Auto Layout)", bundle: .module),
                keywords: ["split", "pane"], defaultShortcut: Shortcut("n", modifiers: [.control, .command]),
                category: .pane, symbol: "rectangle.badge.plus", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "pane new-auto-layout", mainMenu: .view, startsTerminal: true
            ),
            ActionDescriptor(
                id: "toggleSplitZoom",
                title: String(localized: "action.toggleSplitZoom", defaultValue: "Toggle Pane Zoom", bundle: .module),
                keywords: ["maximize", "zoom"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command, .shift]), category: .pane,
                symbol: "arrow.up.left.and.down.right.magnifyingglass", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.pane], cliName: "pane toggle-zoom"
            ),
            ActionDescriptor(
                id: "equalizeSplits",
                title: String(localized: "action.equalizeSplits", defaultValue: "Equalize Splits", bundle: .module),
                keywords: ["balance", "resize"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .shift, .command]), category: .pane,
                symbol: "equal.square", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane equalize-splits", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneLeft",
                title: String(localized: "action.resizePaneLeft", defaultValue: "Resize Pane Left", bundle: .module),
                keywords: ["resize"], defaultShortcut: Shortcut("h", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.left.to.line", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-left", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneRight",
                title: String(localized: "action.resizePaneRight", defaultValue: "Resize Pane Right", bundle: .module),
                keywords: ["resize"], defaultShortcut: Shortcut("l", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.right.to.line", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneUp",
                title: String(localized: "action.resizePaneUp", defaultValue: "Resize Pane Up", bundle: .module),
                keywords: ["resize"], defaultShortcut: Shortcut("k", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.up.to.line.compact", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-up", mainMenu: .view
            ),
            ActionDescriptor(
                id: "resizePaneDown",
                title: String(localized: "action.resizePaneDown", defaultValue: "Resize Pane Down", bundle: .module),
                keywords: ["resize"], defaultShortcut: Shortcut("j", modifiers: [.control, .shift]), category: .pane,
                symbol: "arrow.down.to.line.compact", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane resize-down", mainMenu: .view
            ),
            ActionDescriptor(
                id: "focusLeft",
                title: String(localized: "action.focusLeft", defaultValue: "Focus Pane Left", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.left.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-left"
            ),
            ActionDescriptor(
                id: "focusRight",
                title: String(localized: "action.focusRight", defaultValue: "Focus Pane Right", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.right.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-right"
            ),
            ActionDescriptor(
                id: "focusUp",
                title: String(localized: "action.focusUp", defaultValue: "Focus Pane Above", bundle: .module),
                keywords: ["navigate"], defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.option, .command]),
                category: .pane, symbol: "arrow.up.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-above"
            ),
            ActionDescriptor(
                id: "focusDown",
                title: String(localized: "action.focusDown", defaultValue: "Focus Pane Below", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.option, .command]), category: .pane,
                symbol: "arrow.down.square", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane focus-below"
            ),
            ActionDescriptor(
                id: "focusPreviousPane",
                title: String(localized: "action.focusPreviousPane", defaultValue: "Focus Previous Pane", bundle: .module),
                keywords: ["navigate"], category: .pane, symbol: "arrow.backward.square",
                surfaces: [.palette, .keyboard], targets: [.pane], cliName: "pane focus-previous"
            ),
            ActionDescriptor(
                id: "focusNextPane",
                title: String(localized: "action.focusNextPane", defaultValue: "Focus Next Pane", bundle: .module),
                keywords: ["navigate"], category: .pane, symbol: "arrow.forward.square",
                surfaces: [.palette, .keyboard], targets: [.pane], cliName: "pane focus-next"
            ),
            ActionDescriptor(
                id: "triggerFlash",
                title: String(localized: "action.triggerFlash", defaultValue: "Flash Focused Pane", bundle: .module),
                keywords: ["highlight", "locate"], defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane, symbol: "bolt", surfaces: [.palette, .keyboard, .contextMenu], targets: [.pane],
                cliName: "pane flash-focused"
            ),
            ActionDescriptor(
                id: "palette.swapWithSession",
                title: String(localized: "action.palette.swapWithSession", defaultValue: "Swap With Session…", bundle: .module),
                keywords: ["swap", "exchange"], category: .pane, symbol: "arrow.left.arrow.right",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.panePane], targets: [.pane],
                cliName: "pane swap-with-session"
            ),
            ActionDescriptor(
                id: "increaseWorkspaceTerminalFontSize",
                title: String(localized: "action.increaseWorkspaceTerminalFontSize", defaultValue: "Increase Workspace Font Size", bundle: .module),
                keywords: ["zoom", "bigger"], defaultShortcut: Shortcut("=", modifiers: [.control, .command]),
                category: .pane, symbol: "textformat.size.larger", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane increase-workspace-font-size"
            ),
            ActionDescriptor(
                id: "decreaseWorkspaceTerminalFontSize",
                title: String(localized: "action.decreaseWorkspaceTerminalFontSize", defaultValue: "Decrease Workspace Font Size", bundle: .module),
                keywords: ["zoom", "smaller"], defaultShortcut: Shortcut("-", modifiers: [.control, .command]),
                category: .pane, symbol: "textformat.size.smaller", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane decrease-workspace-font-size"
            ),
            ActionDescriptor(
                id: "resetWorkspaceTerminalFontSize",
                title: String(localized: "action.resetWorkspaceTerminalFontSize", defaultValue: "Reset Workspace Font Size", bundle: .module),
                keywords: ["zoom", "default"], defaultShortcut: Shortcut("0", modifiers: [.control, .command]),
                category: .pane, symbol: "textformat.size", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "pane reset-workspace-font-size"
            ),
            ActionDescriptor(
                id: "toggleCanvasLayout",
                title: String(localized: "action.toggleCanvasLayout", defaultValue: "Toggle Canvas Layout", bundle: .module),
                keywords: ["canvas", "freeform"], defaultShortcut: Shortcut("c", modifiers: [.control, .command]),
                category: .pane, symbol: "rectangle.3.group", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "pane toggle-canvas-layout", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasOverview",
                title: String(localized: "action.canvasOverview", defaultValue: "Canvas Overview", bundle: .module),
                keywords: ["canvas", "expose"], defaultShortcut: Shortcut("o", modifiers: [.control, .command]),
                category: .pane, symbol: "square.grid.3x3", surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-overview", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasTidy",
                title: String(localized: "action.canvasTidy", defaultValue: "Tidy Canvas", bundle: .module),
                keywords: ["canvas", "arrange"], defaultShortcut: Shortcut("t", modifiers: [.control, .command]),
                category: .pane, symbol: "square.grid.2x2.fill", surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane tidy-canvas", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasRevealFocusedPane",
                title: String(localized: "action.canvasRevealFocusedPane", defaultValue: "Reveal Focused Pane on Canvas", bundle: .module),
                keywords: ["canvas", "center"], defaultShortcut: Shortcut("r", modifiers: [.control, .command]),
                category: .pane, symbol: "scope", surfaces: [.palette, .keyboard, .menu], requires: [.canvasLayout],
                targets: [.pane], cliName: "pane reveal-focused-on-canvas", mainMenu: .view
            ),
            ActionDescriptor(
                id: "canvasZoomIn",
                title: String(localized: "action.canvasZoomIn", defaultValue: "Canvas Zoom In", bundle: .module),
                keywords: ["canvas", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.option, .command]),
                category: .pane, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-zoom-in"
            ),
            ActionDescriptor(
                id: "canvasZoomOut",
                title: String(localized: "action.canvasZoomOut", defaultValue: "Canvas Zoom Out", bundle: .module),
                keywords: ["canvas", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.option, .command]),
                category: .pane, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-zoom-out"
            ),
            ActionDescriptor(
                id: "canvasZoomReset",
                title: String(localized: "action.canvasZoomReset", defaultValue: "Canvas Actual Size", bundle: .module),
                keywords: ["canvas", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .pane, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.canvasLayout], targets: [.pane], cliName: "pane canvas-actual-size"
            ),
            ActionDescriptor(
                id: "canvasAlignLeft",
                title: String(localized: "action.canvasAlignLeft", defaultValue: "Align Panes Left", bundle: .module),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.horizontal.left",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane], cliName: "pane align-left"
            ),
            ActionDescriptor(
                id: "canvasAlignRight",
                title: String(localized: "action.canvasAlignRight", defaultValue: "Align Panes Right", bundle: .module),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.horizontal.right",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane align-right"
            ),
            ActionDescriptor(
                id: "canvasAlignTop",
                title: String(localized: "action.canvasAlignTop", defaultValue: "Align Panes Top", bundle: .module),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.vertical.top",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane], cliName: "pane align-top"
            ),
            ActionDescriptor(
                id: "canvasAlignBottom",
                title: String(localized: "action.canvasAlignBottom", defaultValue: "Align Panes Bottom", bundle: .module),
                keywords: ["canvas", "align"], category: .pane, symbol: "align.vertical.bottom",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane align-bottom"
            ),
            ActionDescriptor(
                id: "canvasEqualizeWidths",
                title: String(localized: "action.canvasEqualizeWidths", defaultValue: "Equalize Pane Widths", bundle: .module),
                keywords: ["canvas", "equalize"], category: .pane, symbol: "arrow.left.and.right.square",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane equalize-widths"
            ),
            ActionDescriptor(
                id: "canvasEqualizeHeights",
                title: String(localized: "action.canvasEqualizeHeights", defaultValue: "Equalize Pane Heights", bundle: .module),
                keywords: ["canvas", "equalize"], category: .pane, symbol: "arrow.up.and.down.square",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane equalize-heights"
            ),
            ActionDescriptor(
                id: "canvasDistributeHorizontally",
                title: String(localized: "action.canvasDistributeHorizontally", defaultValue: "Distribute Panes Horizontally", bundle: .module),
                keywords: ["canvas", "distribute"], category: .pane, symbol: "distribute.horizontal.center",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane distribute-horizontally"
            ),
            ActionDescriptor(
                id: "canvasDistributeVertically",
                title: String(localized: "action.canvasDistributeVertically", defaultValue: "Distribute Panes Vertically", bundle: .module),
                keywords: ["canvas", "distribute"], category: .pane, symbol: "distribute.vertical.center",
                surfaces: [.palette, .keyboard], requires: [.canvasLayout], targets: [.pane],
                cliName: "pane distribute-vertically"
            ),
            ActionDescriptor(
                id: "palette.newSimulatorPane",
                title: String(localized: "action.palette.newSimulatorPane", defaultValue: "New Simulator Pane", bundle: .module),
                keywords: ["ios", "simulator", "xcode"], category: .pane, symbol: "iphone", surfaces: [.palette, .menu],
                targets: [.pane], cliName: "pane new-simulator", mainMenu: .view
            ),
            ActionDescriptor(
                id: "simulatorHome",
                title: String(localized: "action.simulatorHome", defaultValue: "Simulator: Home", bundle: .module),
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane, symbol: "house", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-home"
            ),
            ActionDescriptor(
                id: "simulatorRotateLeft",
                title: String(localized: "action.simulatorRotateLeft", defaultValue: "Simulator: Rotate Left", bundle: .module),
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.command]),
                category: .pane, symbol: "rotate.left", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-rotate-left"
            ),
            ActionDescriptor(
                id: "simulatorRotateRight",
                title: String(localized: "action.simulatorRotateRight", defaultValue: "Simulator: Rotate Right", bundle: .module),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.command]), category: .pane,
                symbol: "rotate.right", surfaces: [.keyboard], requires: [.simulatorFocused], targets: [.pane],
                cliName: "pane simulator-rotate-right"
            ),
            ActionDescriptor(
                id: "simulatorToggleAppearance",
                title: String(localized: "action.simulatorToggleAppearance", defaultValue: "Simulator: Toggle Appearance", bundle: .module),
                keywords: ["ios", "simulator", "dark mode"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .shift]), category: .pane,
                symbol: "circle.lefthalf.filled.inverse", surfaces: [.keyboard], requires: [.simulatorFocused],
                targets: [.pane], cliName: "pane simulator-toggle-appearance"
            ),
            ActionDescriptor(
                id: "simulatorToggleSoftwareKeyboard",
                title: String(localized: "action.simulatorToggleSoftwareKeyboard", defaultValue: "Simulator: Toggle Software Keyboard", bundle: .module),
                keywords: ["ios", "simulator"], defaultShortcut: Shortcut("k", modifiers: [.command]), category: .pane,
                symbol: "keyboard", surfaces: [.keyboard], requires: [.simulatorFocused], targets: [.pane],
                cliName: "pane simulator-toggle-software-keyboard"
            ),
            ActionDescriptor(
                id: "palette.openFilesPane",
                title: String(localized: "action.palette.openFilesPane", defaultValue: "Open Files as Pane", bundle: .module),
                keywords: ["explorer", "pane"], category: .pane, symbol: "doc.text", surfaces: [.palette],
                targets: [.pane], cliName: "pane open-files-as"
            ),
            ActionDescriptor(
                id: "palette.openFindPane",
                title: String(localized: "action.palette.openFindPane", defaultValue: "Open Find as Pane", bundle: .module),
                keywords: ["search", "pane"], category: .pane, symbol: "text.magnifyingglass", surfaces: [.palette],
                targets: [.pane], cliName: "pane open-find-as"
            ),
            ActionDescriptor(
                id: "palette.openVaultPane",
                title: String(localized: "action.palette.openVaultPane", defaultValue: "Open Vault as Pane", bundle: .module),
                keywords: ["sessions", "pane"], category: .pane, symbol: "archivebox", surfaces: [.palette],
                targets: [.pane], cliName: "pane open-vault-as"
            ),
            ActionDescriptor(
                id: "palette.openCloudPane",
                title: String(localized: "action.palette.openCloudPane", defaultValue: "Open Cloud as Pane", bundle: .module),
                keywords: ["machines", "pane"], category: .pane, symbol: "cloud", surfaces: [.palette],
                targets: [.pane], cliName: "pane open-cloud-as"
            ),
        ]
    }
}

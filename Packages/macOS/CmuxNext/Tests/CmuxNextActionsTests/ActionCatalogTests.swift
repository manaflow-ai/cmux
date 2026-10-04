import AppKit
import CmuxNextActions
import Foundation
import Testing

/// Catalog completeness against plans/cmux-next/inventory.md section 1.
@Suite struct ActionCatalogTests {
    /// Every `KeyboardShortcutSettings.Action` ID named in the inventory. Users
    /// store these in `cmux.json`, so each must exist with the same spelling.
    static let keyboardShortcutIDs: [ActionID] = [
        // Window / app
        "openSettings", "newWindow", "closeWindow", "toggleFullScreen", "quit", "showHideAllWindows",
        "globalSearch", "commandPalette", "commandPaletteNext", "commandPalettePrevious", "goToWorkspace",
        "focusHistoryBack", "focusHistoryForward", "focusHistoryLast",
        // Workspace
        "newTab", "newBrowserWorkspace", "openFolder", "reopenPreviousSession", "reopenClosedWorkspace",
        "nextSidebarTab", "prevSidebarTab", "nextSidebarTabInGroup", "prevSidebarTabInGroup",
        "moveWorkspaceUp", "moveWorkspaceDown", "selectWorkspaceByNumber", "renameWorkspace",
        "editWorkspaceDescription", "markWorkspaceDone", "cycleWorkspaceStatus", "toggleChecklistItemComplete",
        "closeWorkspace", "newWorkspaceGroup", "groupSelectedWorkspaces", "toggleFocusedWorkspaceGroupCollapsed",
        "saveLayoutTemplate",
        // Pane
        "splitRight", "splitDown", "newPaneAutoLayout", "toggleSplitZoom", "equalizeSplits",
        "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown",
        "focusLeft", "focusRight", "focusUp", "focusDown", "focusPreviousPane", "focusNextPane", "triggerFlash",
        "increaseWorkspaceTerminalFontSize", "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize",
        "toggleCanvasLayout", "canvasOverview", "canvasTidy", "canvasRevealFocusedPane",
        "canvasZoomIn", "canvasZoomOut", "canvasZoomReset",
        "simulatorHome", "simulatorRotateLeft", "simulatorRotateRight", "simulatorToggleAppearance",
        "simulatorToggleSoftwareKeyboard",
        // Tab
        "newSurface", "openBrowser", "closeTab", "closeOtherTabsInPane", "renameTab", "nextSurface", "prevSurface",
        "moveSurfaceLeft", "moveSurfaceRight", "moveSurfaceToPreviousPane", "moveSurfaceToNextPane",
        "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
        "selectSurfaceByNumber", "reopenClosedBrowserPanel",
        // Terminal
        "toggleTerminalCopyMode", "focusTextBoxInput", "cycleTextBoxSubmitAction", "attachTextBoxFile",
        "sendCtrlFToTerminal", "pasteLastScreenshot", "clearScreenKeepScrollback",
        "find", "findInDirectory", "findNext", "findPrevious", "hideFind", "useSelectionForFind",
        // Browser / viewers
        "browserBack", "browserForward", "browserReload", "browserHardReload", "focusBrowserAddressBar",
        "browserZoomIn", "browserZoomOut", "browserZoomReset", "markdownZoomIn", "markdownZoomOut", "markdownZoomReset",
        "toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "toggleBrowserFocusMode",
        "toggleBrowserDesignMode", "toggleReactGrab", "splitBrowserRight", "splitBrowserDown",
        "saveFilePreview", "toggleFileEditorWordWrap", "openDiffViewer",
        // Sidebar
        "toggleSidebar", "toggleRightSidebar", "focusRightSidebar",
        "switchRightSidebarToFiles", "switchRightSidebarToFind", "switchRightSidebarToSessions",
        "switchRightSidebarToFeed", "switchRightSidebarToDock", "switchRightSidebarToMachines",
        "fileExplorerOpenSelection", "fileExplorerOpenSelectionFinderAlias",
        // Notifications
        "showNotifications", "jumpToUnread", "toggleUnread", "markOldestUnreadAndJumpNext",
        "markAllNotificationsRead", "clearAllNotifications",
        // Cloud / account
        "newCloudWorkspace", "newCloudMachine", "openTeamPicker",
        // Settings / help
        "reloadConfiguration", "sendFeedback",
    ]

    /// Counts generated from the catalog and checked into plans/cmux-next/actions.md.
    /// Regenerate with `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter ActionSurfaceParityTests`.
    static func generatedCounts() throws -> [ActionCategory: Int] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plans/cmux-next/actions.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "## Catalog counts\n\n"))
        let end = try #require(text.range(of: "\n## Counts (", range: start.upperBound..<text.endIndex))
        var counts: [ActionCategory: Int] = [:]
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let fields = line.split { $0 == "`" || $0 == ":" }
            guard fields.count == 3, fields[0].hasPrefix("- "), let count = Int(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let category = ActionCategory(rawValue: String(fields[1])) else { continue }
            counts[category] = count
        }
        return counts
    }


    @Test func everyKeyboardShortcutIDExists() {
        let ids = Set(ActionCatalog.all.map(\.id))
        let missing = Self.keyboardShortcutIDs.filter { !ids.contains($0) }
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    @Test func countsByDomainMatchInventory() throws {
        let expected = try Self.generatedCounts()
        var counts: [ActionCategory: Int] = [:]
        for descriptor in ActionCatalog.all { counts[descriptor.category, default: 0] += 1 }
        for category in ActionCategory.allCases where category != .other {
            #expect(counts[category] == expected[category], "\(category)")
        }
        #expect(counts == expected)
    }

    @Test func idsAreUniqueAndTitlesPresent() {
        let ids = ActionCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for descriptor in ActionCatalog.all {
            #expect(!descriptor.title.isEmpty, "\(descriptor.id)")
            #expect(!descriptor.symbol.isEmpty, "\(descriptor.id)")
            #expect(!descriptor.surfaces.isEmpty, "\(descriptor.id)")
        }
    }

    @Test func cloudMachineIOActionsAreTerminalAndReachable() throws {
        let ssh = try #require(ActionCatalog.all.first { $0.id == "cloudSSH" })
        #expect(ssh.startsTerminal)
        #expect(ssh.cliName == "cloud ssh")
        #expect(ssh.surfacePlan.contextMenus.map(\.context) == [.cloudMachine])

        let exec = try #require(ActionCatalog.all.first { $0.id == "cloudExec" })
        #expect(exec.startsTerminal)
        #expect(exec.cliName == "cloud exec")
        #expect(exec.arguments.map(\.name) == ["command"])
    }

    @Test func standardCatalogHasNoUnresolvableShortcutConflicts() {
        let registry = ActionRegistry.standard()
        #expect(registry.shortcutConflicts().isEmpty, "\(registry.shortcutConflicts())")
    }

    /// HQ #1259 section 5c: readline, TUI and editor keys must reach the
    /// terminal, regardless of an action's routing tier. Bind every handler
    /// so an unimplemented action cannot hide a forbidden default. The old
    /// Control-Shift H/J/K/L resize defaults are included deliberately.
    @Test func neverTakeFromTerminalDefaultsStayOutOfTheResolver() {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors {
            _ = registry.bind(descriptor.id) {}
        }
        let bindings = RegistryKeyBindings(registry)
        for facts: ActionContext in [[], [.signedIn, .cloudWorkspace, .canvasLayout], [.signedOut]] {
            registry.context = facts.union(.terminalFocused)
            var context = KeyContext(bits: registry.context)
            context[KeyContext.surfaceKind] = .string("terminal")
            context[KeyContext.focus] = .string("content")
            for shortcut in Self.neverTakeFromTerminal {
                #expect(registry.resolve(shortcut) == nil, "terminal key claimed by \(shortcut.displayString)")
                let result = bindings.table.resolve([shortcut], in: context) {
                    bindings.canPerform($0, in: registry.context)
                }
                #expect(result.winner == nil, "terminal keymap claims \(shortcut.displayString)")
            }
        }
    }

    private static var neverTakeFromTerminal: [Shortcut] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz").flatMap { character in
            let key = String(character)
            return [
                Shortcut(key, modifiers: [.control]),
                Shortcut(key, modifiers: [.control, .shift]),
                Shortcut(key, modifiers: [.option]),
            ]
        }
        let controlKeys = ["[", "]", "\\", "^", "_", "@", Shortcut.spaceKey].map {
            Shortcut($0, modifiers: [.control])
        }
        let optionKeys = [
            Shortcut.leftArrowKey, Shortcut.rightArrowKey, Shortcut.upArrowKey, Shortcut.downArrowKey,
            Shortcut.returnKey, Shortcut.deleteKey, "\u{7F}",
        ].map { Shortcut($0, modifiers: [.option]) }
        let functionKeys = (NSF1FunctionKey...NSF12FunctionKey).map { String(UnicodeScalar($0)!) }
        let tuiKeys = ([
            Shortcut.escapeKey, Shortcut.tabKey, Shortcut.returnKey,
            String(UnicodeScalar(NSHomeFunctionKey)!), String(UnicodeScalar(NSEndFunctionKey)!),
            KeyBindingDefaults.pageUp, KeyBindingDefaults.pageDown,
        ] + functionKeys).map { Shortcut($0, modifiers: []) }
        // Ctrl-minus history and Ctrl-digit selection were explicitly approved
        // in #1259. Neither is part of this terminal-owned list. Cmd-C/V have
        // terminal-scoped handlers checked below; Cmd-K stays with Ghostty.
        return letters + controlKeys + optionKeys + tuiKeys + [
            Shortcut(Shortcut.tabKey, modifiers: [.shift]),
            Shortcut(Shortcut.returnKey, modifiers: [.shift]),
            Shortcut("k", modifiers: [.command]),
        ]
    }

    /// Clipboard and clear-screen actions remain terminal-scoped content
    /// actions, so their Cmd-C, Cmd-V and Cmd-Shift-K ownership wins only
    /// while a terminal has the keyboard.
    @Test func terminalEditingDefaultsStayContentScoped() throws {
        let expected: [ActionID: Shortcut] = [
            "terminalCopy": Shortcut("c", modifiers: [.command]),
            "terminalPaste": Shortcut("v", modifiers: [.command]),
            "clearScreenKeepScrollback": Shortcut("k", modifiers: [.command, .shift]),
        ]
        for (id, shortcut) in expected {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.requires.contains(.terminalFocused), "\(id) must require terminal focus")
            #expect(ActionKeyTier.defaultTier(for: descriptor) == .content, "\(id) must be content-tier")
            #expect(descriptor.defaultShortcut == shortcut, "\(id) shortcut")
        }
    }

    @Test func legacyAliasesPointAtCatalogIDs() {
        let ids = Set(ActionCatalog.all.map(\.id))
        for (legacy, canonical) in ActionCatalog.legacyAliases {
            #expect(ids.contains(canonical), "\(legacy) -> \(canonical)")
        }
    }
}

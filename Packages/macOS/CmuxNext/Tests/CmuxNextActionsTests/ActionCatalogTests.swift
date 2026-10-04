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

    /// Navigation defaults run ahead of a focused terminal. Keep the
    /// terminal's readline, TUI and editor controls available by never
    /// taking plain Control-letter, Control-Shift-letter or Option-letter
    /// bindings in that tier. Numbered Control shortcuts and the approved
    /// Control-Command pane resize family are intentionally outside this
    /// list.
    @Test func navigationDefaultsDoNotTakeTerminalEditingKeys() {
        let violations = ActionCatalog.all.compactMap { descriptor -> String? in
            guard let shortcut = descriptor.defaultShortcut,
                  ActionKeyTier.defaultTier(for: descriptor) == .navigation,
                  shortcut.key.rangeOfCharacter(from: .letters) != nil,
                  shortcut.key.count == 1 else { return nil }
            let terminalKey = shortcut.modifiers == [.control]
                || shortcut.modifiers == [.control, .shift]
                || shortcut.modifiers == [.option]
            return terminalKey ? "\(descriptor.id): \(shortcut.displayString)" : nil
        }
        #expect(violations.isEmpty, "navigation defaults take terminal keys: \(violations)")
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

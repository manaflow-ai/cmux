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
        let endRange = text.range(of: "\n## Counts (", range: start.upperBound..<text.endIndex)
        let end = try #require(endRange)
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

    /// Compared only where CI checks the committed exports (CMUX_CHECK_GENERATED_EXPORTS=1,
    /// check-action-surfaces.sh) or rewrites them; on feat-cmux-next the autofix bots
    /// regenerate them (regenerate-action-exports.sh).
    @Test(.enabled(if: ["CMUX_CHECK_GENERATED_EXPORTS", "CMUX_UPDATE_ACTION_SURFACES"].contains { ProcessInfo.processInfo.environment[$0] == "1" })) func countsByDomainMatchInventory() throws {
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
            // An automation-only action (agent.openSessionWorkspace) has no
            // human surface; its surface plan names why the palette omits it.
            #expect(!descriptor.surfaces.isEmpty || descriptor.surfacePlan.palette.exemption != nil, "\(descriptor.id)")
        }
    }

    /// Session Info and the ACP event Inspector are separate panels and palette actions.
    @Test func sessionInfoToggleUsesTheHeaderNameAndKeywords() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "agentPane.toggleSessionInfo" })
        #expect(action.title == "Toggle Session Info")
        #expect(action.surfaces.contains(.palette))
        #expect(action.keywords.contains("session info"))
        #expect(action.keywords.contains("session"))
        #expect(action.requires.contains(.agentPaneFocused))
        let events = try #require(ActionCatalog.all.first { $0.id == "agentPane.toggleInspector" })
        #expect(events.title == "Toggle Event Inspector")
        #expect(events.surfaces.contains(.palette))
        #expect(events.cliName == "agent toggle-acp-inspector")
    }

    /// Palette and menu titles use title case (HIG): every word is capitalized except
    /// short articles, conjunctions and prepositions, and names spelled in lowercase.
    @Test func titlesUseTitleCase() {
        let minor: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at",
                                  "by", "in", "of", "on", "to", "up", "via", "vs", "from", "into", "with", "onto", "over", "than"]
        for descriptor in ActionCatalog.all {
            let words = descriptor.title.split(whereSeparator: { $0 == " " || $0 == "/" }).map {
                $0.trimmingCharacters(in: CharacterSet.letters.inverted)
            }
            for (index, word) in words.enumerated() {
                guard let first = word.first, first.isLowercase else { continue }
                if word.hasPrefix("cmux") || word.contains(".") { continue }
                #expect(index > 0 && minor.contains(word), "\(descriptor.id): \"\(descriptor.title)\"")
            }
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

    @Test func browserHistoryOwnsCmdYAndRightSidebarHasNoDigitDefaults() throws {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        let browserHistory = try #require(byID["browserShowHistory"])
        #expect(browserHistory.defaultShortcut == Shortcut("y", modifiers: [.command]))
        #expect(browserHistory.requires.contains(.browserFocused))
        #expect(byID["newCloudMachine"]?.defaultShortcut != Shortcut("y", modifiers: [.command]))

        for id: ActionID in [
            "switchRightSidebarToFiles", "switchRightSidebarToFind", "switchRightSidebarToSessions",
            "switchRightSidebarToFeed", "switchRightSidebarToDock", "switchRightSidebarToMachines",
        ] {
            #expect(byID[id]?.defaultShortcut == nil, "\(id) must not claim a default shortcut")
        }
    }

    @Test func legacyAliasesPointAtCatalogIDs() {
        let ids = Set(ActionCatalog.all.map(\.id))
        for (legacy, canonical) in ActionCatalog.legacyAliases {
            #expect(ids.contains(canonical), "\(legacy) -> \(canonical)")
        }
    }

    @Test func minimapKeywordBelongsToEditorAndTranscriptSurfaces() throws {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        let stripScrollbar = try #require(byID["layout.toggleStripScrollbar"])
        #expect(!stripScrollbar.keywords.contains("minimap"))
        #expect(stripScrollbar.keywords.contains("column"))
        #expect(stripScrollbar.keywords.contains("strip"))
        #expect(stripScrollbar.keywords.contains("scrollbar"))
        #expect(stripScrollbar.keywords.contains("visible range"))
        #expect(stripScrollbar.keywords.contains("overview"))

        let transcriptActions = ["agentPane.previousTurn", "agentPane.nextTurn"].compactMap { byID[$0] }
        #expect(transcriptActions.count == 2)
        #expect(transcriptActions.allSatisfy { $0.keywords.contains("minimap") })
    }

    /// Leo, 2026-10-25: "minimap? i dont see any command for the vscode minimap".
    @Test func editorMinimapToggleIsAPaletteCommand() throws {
        let toggle = try #require(ActionCatalog.all.first { $0.id == "toggleFileEditorMinimap" })
        #expect(toggle.isPaletteVisible)
        #expect(toggle.requires.contains(.codeEditorFocused))
        #expect(toggle.keywords.contains("minimap"))
        #expect(toggle.keywords.contains("vscode"))
    }

    @Test func completeConversationCopyIsReachableFromThePalette() throws {
        let copy = try #require(ActionCatalog.all.first { $0.id == "agentChat.copyConversation" })
        #expect(copy.surfaces.contains(.palette))
        #expect(copy.requires.contains(.agentPaneFocused))
        #expect(copy.keywords.contains("conversation"))
        #expect(copy.keywords.contains("markdown"))
    }

    @Test func sessionFileCopiesAreReachableFromThePalette() throws {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        let ids: [ActionID] = ["agentChat.copySessionFilePaths", "agentChat.copyTranscriptFile", "agentChat.copyHarnessConfigFile",
                               "agentChat.copyHarnessSettingsFile", "agentChat.copyAcpmuxSessionFile"]
        for id in ids {
            let action = try #require(byID[id])
            #expect(action.surfaces.contains(.palette))
            #expect(action.requires.contains(.agentPaneFocused))
        }
        #expect(byID["agentChat.copyHarnessConfigFile"]?.keywords.contains("claude.json") == true)
        #expect(byID["agentChat.copyTranscriptFile"]?.keywords.contains("jsonl") == true)
    }
}

import CmuxSettings
import Testing
@testable import CmuxSettingsUI

/// Guards the search-result highlight bridge in both directions:
///
/// - **Forward** — every cmux.json path a `SettingsCardRow` declares via
///   `configurationReview` resolves to a real indexed entry, so the row
///   carries the same `.id` its search hit posts.
/// - **Inverse** — every curated search result (the things that appear
///   in the sidebar search list) is reachable: some row anchor equals
///   its entry id, so clicking it scrolls to and highlights a row.
///
/// `rowConfigPaths` mirrors the `.json(...)` annotations across
/// `Sections/*.swift`. `explicitlyAnchoredEntryIDs` lists the searchable
/// rows that carry an explicit `settingsSearchAnchors([...])` instead of
/// a cmux.json path (pickers and action buttons that don't write a
/// single key). Together they must cover every curated setting entry.
@Suite("SettingsRowAnchorResolution")
struct SettingsRowAnchorResolutionTests {
    /// Every singular cmux.json path declared by an *unconditionally
    /// rendered* settings row. Excludes rows that aren't standalone search
    /// results: `workspaceColors.colors` (repeated per-palette rows) and
    /// the conditional sub-fields that are hidden in the default state —
    /// `automation.socketPassword` (only in password mode),
    /// `browser.customSearchEngineName` / `customSearchEngineURLTemplate`
    /// (only when the engine is Custom). Those would be dead search hits
    /// when hidden, so their search terms fold into the always-visible
    /// parent (Socket Control Mode / Default Search Engine) instead.
    ///
    /// This is a deliberately hand-maintained contract list: the rows live
    /// in SwiftUI view bodies (`Sections/*.swift`) that can't be reflected
    /// from a test, so there's no `Mirror`-style seam to derive it. Adding
    /// a settings row means adding its path here. Two companion tests bound
    /// the drift this can't catch on its own: ``everyCuratedSettingEntryIsReachable``
    /// fails if a curated search result has no backing anchor, and
    /// ``rowAnchorsAreUniqueAcrossRows`` fails if two rows collide on one id.
    static let rowConfigPaths: [String] = [
        "app.commandPaletteSearchesAllSurfaces",
        "app.confirmQuit",
        "app.focusPaneOnFirstClick",
        "app.globalFontMagnification",
        "app.hideTabCloseButton",
        "app.iMessageMode",
        "app.keepWorkspaceOpenWhenClosingLastSurface",
        "app.language",
        "app.menuBarOnly",
        "app.minimalMode",
        "app.newWorkspacePlacement",
        "app.openMarkdownInCmuxViewer",
        "app.openSupportedFilesInCmux",
        "app.preferredEditor",
        "app.renameSelectsExistingName",
        "app.reorderOnNotification",
        "app.sendAnonymousTelemetry",
        "app.warnBeforeClosingTab",
        "app.warnBeforeClosingTabXButton",
        "app.workspaceInheritWorkingDirectory",
        "automation.claudeBinaryPath",
        "automation.claudeCodeIntegration",
        "automation.cursorIntegration",
        "automation.geminiIntegration",
        "automation.portBase",
        "automation.portRange",
        "automation.ripgrepBinaryPath",
        "automation.socketControlMode",
        "automation.suppressSubagentNotifications",
        "automation.workspaceAutoNaming",
        "browser.defaultSearchEngine",
        "browser.discardHiddenWebViews",
        "browser.hiddenWebViewDiscardDelaySeconds",
        "browser.askWhereToSaveDownloads",
        "browser.hostsToOpenInEmbeddedBrowser",
        "browser.interceptTerminalOpenCommandInCmuxBrowser",
        "browser.openTerminalLinksInCmuxBrowser",
        "browser.reactGrabVersion",
        "browser.showSearchSuggestions",
        "browser.theme",
        "browser.urlsToAlwaysOpenExternally",
        "canvas.paneGap",
        "canvas.snappingEnabled",
        "customSidebars.renderer",
        "fileEditor.wordWrap",
        "notifications.command",
        "notifications.dockBadge",
        "notifications.paneFlash",
        "notifications.showInMenuBar",
        "notifications.sound",
        "notifications.unreadPaneRing",
        "sidebar.branchLayout",
        "sidebar.hideAllDetails",
        "sidebar.makePullRequestsClickable",
        "sidebar.openPortLinksInCmuxBrowser",
        "sidebar.openPullRequestLinksInCmuxBrowser",
        "sidebar.pathLastSegmentOnly",
        "sidebar.rightMaxWidth",
        "sidebar.showBranchDirectory",
        "sidebar.showCustomMetadata",
        "sidebar.showLog",
        "sidebar.showNotificationMessage",
        "sidebar.showPorts",
        "sidebar.showProgress",
        "sidebar.showPullRequests",
        "sidebar.showSSH",
        "sidebar.showWorkspaceDescription",
        "sidebar.workspaceControls",
        "sidebar.stackBranchDirectory",
        "sidebar.watchGitStatus",
        "sidebar.wrapWorkspaceTitles",
        "sidebarAppearance.matchTerminalBackground",
        "shortcuts.showModifierHoldHints",
        "terminal.agentHibernation.enabled",
        "terminal.agentHibernation.idleSeconds",
        "terminal.agentHibernation.maxLiveTerminals",
        "terminal.rendererRealization.enabled",
        "terminal.rendererRealization.idleSeconds",
        "terminal.rendererRealization.maxWarmRenderers",
        "terminal.autoResumeAgentSessions",
        "terminal.copyOnSelect",
        "terminal.resumeCommands",
        "terminal.focusTextBoxOnNewTerminals",
        "terminal.scrollSpeed",
        "terminal.showScrollBar",
        "terminal.showTextBoxOnNewTerminals",
        "terminal.textBoxMaxLines",
        "workspaceColors.indicatorStyle",
        "workspaceColors.notificationBadgeColor",
        "workspaceColors.selectionColor",
    ]

    /// Searchable rows anchored with an explicit `settingsSearchAnchors`
    /// (no single cmux.json path): pickers and action buttons. Each must
    /// match the corresponding curated entry id verbatim.
    static let explicitlyAnchoredEntryIDs: Set<String> = [
        "setting:app:appearance",
        "setting:app:app-icon",
        "setting:app:file-drops",
        "setting:app:terminal-config",
        "setting:app:desktop-notifications",
        "setting:account:account",
        "setting:mobile:pairDevice",
        "setting:mobile:iOSPairingHost",
        "setting:mobile:iOSPairingPort",
        "setting:mobile:iOSPairingDisplayName",
        "setting:betaFeatures:feed",
        "setting:betaFeatures:dock",
        "setting:betaFeatures:customSidebars",
        "setting:betaFeatures:remoteTmux",
        "setting:betaFeatures:workspaceTasks",
        "setting:betaFeatures:workspaceControls",
        "setting:sidebarAppearance:workspace-controls",
        "setting:customSidebars:enabled",
        "setting:browser:history",
        "setting:browser:http-allowlist",
        "setting:workspaceColors:palette",
        "setting:browser:enable-browser",
        "setting:browserImport:import-data",
        "setting:browserImport:import-hint",
        "setting:globalHotkey:enable-hotkey",
        "setting:globalHotkey:shortcut",
        "setting:keyboardShortcuts:shortcuts",
        "setting:keyboardShortcuts:shortcut-chords",
        "setting:keyboardShortcuts:reset-defaults",
        "setting:terminal:memory-guardrail",
        "setting:terminal:memory-guardrail-threshold",
        "setting:settingsJSON:open-file",
        "setting:settingsJSON:documentation",
        "setting:reset:reset-all",
    ]

    @Test(arguments: rowConfigPaths)
    func everyRowPathResolvesToAnIndexedEntry(path: String) throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let anchor = try #require(
            index.anchorID(forSettingsPath: path),
            "no anchor for row path \(path) — its search hit won't scroll/highlight"
        )
        #expect(
            index.entries.contains { $0.id == anchor },
            "anchor \(anchor) for \(path) is not a real indexed entry"
        )
    }

    /// The user-facing contract: every result in the sidebar search list
    /// can be scrolled to and highlighted. A curated setting entry is
    /// reachable when some row anchor equals its id — either a row whose
    /// `configurationReview` path resolves to it, or a row explicitly
    /// tagged with its id.
    @Test
    func everyCuratedSettingEntryIsReachable() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let pathBackedIDs = Set(Self.rowConfigPaths.compactMap { index.anchorID(forSettingsPath: $0) })
        let sectionIDs = Set(SettingsSectionID.allCases.map { "section:\($0.rawValue)" })
        let reachable = pathBackedIDs
            .union(Self.explicitlyAnchoredEntryIDs)
            .union(sectionIDs)

        let unreachable = index.entries
            .filter { if case .setting = $0.kind { return true } else { return false } }
            .filter { $0.anchorID == $0.id }
            .map(\.id)
            .filter { !reachable.contains($0) }
        let brokenAliasedAnchors = index.entries
            .filter { if case .setting = $0.kind { return true } else { return false } }
            .filter { $0.anchorID != $0.id }
            .map(\.anchorID)
            .filter { !reachable.contains($0) }

        #expect(
            unreachable.isEmpty,
            "these search results have no row to scroll to / highlight: \(unreachable.sorted())"
        )
        #expect(
            brokenAliasedAnchors.isEmpty,
            "these aliased search results point to non-reachable anchors: \(brokenAliasedAnchors.sorted())"
        )
    }

    /// A setting search hit must select a real row anchor, not merely
    /// dump the user at the owning section. Section-only setting hits are
    /// dead ends for scroll/highlight and usually mean an internal
    /// persistence key leaked into the search index.
    @Test
    func settingEntriesDoNotUseSectionOnlyAnchors() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let sectionIDs = Set(SettingsSectionID.allCases.map { "section:\($0.rawValue)" })
        let sectionOnlySettings = index.entries
            .filter { if case .setting = $0.kind { return true } else { return false } }
            .filter { sectionIDs.contains($0.anchorID) }
            .map(\.id)

        #expect(
            sectionOnlySettings.isEmpty,
            "these search results only navigate to a section instead of a row anchor: \(sectionOnlySettings.sorted())"
        )
    }

    /// No two distinct rows may resolve to the same anchor id. Each entry
    /// in ``rowConfigPaths`` is one row's primary path; if two resolve to
    /// the same id, both rows get that `.id`, making `proxy.scrollTo`
    /// ambiguous and the highlight land on the wrong/multiple rows. This
    /// guards the class of bug where a curated entry's synonyms carried
    /// several sub-paths (e.g. agentHibernation.enabled/idleSeconds/...)
    /// so every sub-row collided on one anchor.
    /// The DEBUG `:all` sentinel surfaces every indexed entry so the
    /// full search → scroll → highlight path can be walked row by row.
    @Test
    func debugSentinelReturnsEveryEntry() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let all = index.match(":all")
        #expect(all.count == index.entries.count)
        #expect(Set(all.map(\.id)) == Set(index.entries.map(\.id)))
        // A normal query is still filtered, so the sentinel isn't just
        // "everything always".
        #expect(index.match("copy on select").count < index.entries.count)
    }

    @Test
    func rowAnchorsAreUniqueAcrossRows() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        var firstPath: [String: String] = [:]
        for path in Self.rowConfigPaths {
            guard let anchor = index.anchorID(forSettingsPath: path) else { continue }
            if let prior = firstPath[anchor] {
                Issue.record("anchor \(anchor) is shared by rows '\(prior)' and '\(path)' — duplicate .id breaks scrollTo")
            } else {
                firstPath[anchor] = path
            }
        }
    }
}

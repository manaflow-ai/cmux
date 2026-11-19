/// The reviewed classes of the catalog's actions that no catalog field and no hand list of ControlRouter decides
/// (`CallerActionClassTests`): an action that takes a tab, pane, screen or workspace, or a group of one, runs on
/// its caller's own one (``ownPlace``), any other is not affected by a caller (``unaffected``). Neither closes,
/// ends, archives, disconnects or destroys what it runs on, and no ``unaffected`` one changes the tab, pane,
/// workspace or window the person has in front when the run has no target; that is what the review of each id
/// says. Second pass, 2026-11-18 (review of 4fb5810d35c), by reading the handlers: 163 actions left
/// ``unaffected``: 93 group actions and 8 that read the run's tab, pane or workspace to ``ownPlace``; 55 on a
/// window, a Space or a bookmark and 7 on the front window or its Chief to `CallerActionClass.personsFront`.
/// Still ``unaffected`` and not read one by one: actions on a machine, a browser profile, a sidebar row or
/// section (their handlers ask for a named one, or take the front window's machine), and actions that show a
/// page, a palette or a dialog in the front window (the view-change rule's).
///
/// A new action of the catalog is in neither list, and the test fails until someone decides: a closing action goes
/// to `ControlRouter.closingActions` (or is destructive in the catalog), one that closes a window's workspaces or
/// windows to `ControlRouter.windowClosingActions`, one that changes the front window or its Chief to
/// `ControlRouter.frontWindowActions`, one whose handler places a new tab beside an agent to
/// `ControlRouter.besideCallerActions` (a browser tab: `profileBrowserActions`); any other goes into the list below that `ControlRouter.callerClass(of:)`
/// gives it. An action whose target kinds change moves between the lists the same way.
struct CallerActionClassReview {
    /// Reviewed 2026-11-18 (751 actions).
    static let ownPlace = ids("""
        agent.openSessionTab agent.share agent.share.invite agent.share.list agent.share.uninvite agentChat.copyAcpmuxSessionFile
        agentChat.copyConversation agentChat.copyHarnessConfigFile agentChat.copyHarnessSessionID agentChat.copyHarnessSettingsFile
        agentChat.copyHost agentChat.copyIdentifier agentChat.copyName agentChat.copySessionDetails agentChat.copySessionFilePaths
        agentChat.copyTranscriptFile agentChat.copyWorkingDirectory agentChat.subagentLimit agentChat.toggleNotificationMute
        agentHistory.show agentPane.addProjectFiles agentPane.continueAfterError agentPane.continueIn agentPane.copyLastCodeBlock
        agentPane.createCheckpoint agentPane.editInstructions agentPane.git.commit agentPane.git.push agentPane.markUnread
        agentPane.moveToFloatingChat agentPane.nextBookmarkedPrompt agentPane.nextTurn agentPane.openCwdInTerminal
        agentPane.permission.allowChat agentPane.permission.allowOnce agentPane.permission.deny agentPane.permission.expand
        agentPane.permission.refresh agentPane.permission.retry agentPane.previousBookmarkedPrompt agentPane.previousTurn
        agentPane.replayConversation agentPane.revealCwdInFinder agentPane.runInBackground agentPane.searchFiles agentPane.setEffort
        agentPane.setMode agentPane.setModel agentPane.showBackgroundTasks agentPane.showInMini agentPane.showSubagents
        agentPane.sideQuestion agentPane.switchModel agentPane.toggleDisplaySettings agentPane.toggleFiles agentPane.toggleInspector
        agentPane.toggleMinimap agentPane.togglePreview agentPane.toggleQueueing agentPane.toggleSessionInfo agentPane.toggleSideTabs
        agentPaneZoomIn agentPaneZoomOut agentPaneZoomReset app.menu.run appearance.changeBackground appearance.reset appearance.set
        attachTextBoxFile bookmark.addAllTabs bookmark.addPage browser.cast browser.certificateWarning.goBack
        browser.certificateWarning.proceed browser.copyURL browser.createQRCode browser.download.copyLink browser.download.open
        browser.download.retry browser.download.reveal browser.download.togglePause browser.downloads.show browser.editSource
        browser.extension.command browser.extension.details browser.extension.disable browser.extension.enable browser.extension.homePage
        browser.extension.move browser.extension.options browser.extension.pin browser.extension.reload browser.extension.run
        browser.extension.siteAccess browser.extension.unpin browser.extension.webPermissions browser.extensions.loadUnpacked
        browser.extensions.manage browser.extensions.menu browser.extensions.webStore browser.findPrevious browser.focusSearch
        browser.goToHistoryEntry browser.image.copy browser.image.copyAddress browser.image.openInNewTab browser.image.saveAs
        browser.link.copy browser.link.copyText browser.link.openInIncognitoWindow browser.link.openInNewSpace browser.link.openInNewTab
        browser.link.openInNewWindow browser.link.openInNewWorkspace browser.link.openInSplit browser.link.saveAs browser.media.show
        browser.openInChromium browser.openInWebKit browser.openLocally browser.openOnMachine browser.overflow.menu browser.pageInfo
        browser.pageInfo.aboutThisPage browser.pageInfo.certificate browser.pageInfo.connection browser.pageInfo.cookies
        browser.pageInfo.manageSiteData browser.pageInfo.reenableCertificateWarnings browser.pageInfo.setPermission
        browser.pageInfo.siteSettings browser.profile.choose browser.prompt.allow browser.prompt.block browser.resetPinnedTab
        browser.savePageAs browser.selection.copy browser.selection.lookUp browser.selection.search browser.translate browserBack
        browserDevice browserFit browserFitDesktop browserFitDesktop1280 browserForward browserHardReload browserLinkHints
        browserLinkHintsNewSplit browserPrint browserProfile.clearWorkspaceDefault browserProfile.duplicateTab
        browserProfile.manageExtensions browserProfile.moveTab browserProfile.openLinkInNew browserProfile.setWorkspaceDefault
        browserReload browserScreenshotPage browserScreenshotSection browserScrollDown browserScrollToBottom browserScrollToTop
        browserScrollUp browserStop browserTheme browserZoomIn browserZoomOut browserZoomReset canvasAlignBottom canvasAlignLeft
        canvasAlignRight canvasAlignTop canvasDistributeHorizontally canvasDistributeVertically canvasEqualizeHeights canvasEqualizeWidths
        canvasOverview canvasRevealFocusedPane canvasTidy canvasZoomIn canvasZoomOut canvasZoomReset checklistAttachImages
        checklistCompleteItem checklistEditItem checklistMarkInProgress checklistOpenAsPane checklistRemoveItem clearScreenKeepScrollback
        clearWorkspaceNotifications cloud.team.copyLink cloud.team.follow cloud.team.reassign cloud.team.session cloud.team.unfollow
        cloudBringBack cloudMove cloudMoveToMachine cloudTransferLocal column.center column.cycleWidth column.cycleWidthBack column.dock
        column.dockBottom column.dockLeft column.dockRight column.dockTop column.float column.focusLeft column.focusRight column.moveLeft
        column.moveRight column.undock column.widthFull column.widthHalf column.widthOneThird column.widthTwoThirds copyWorkspaceSSHError
        cycleTextBoxSubmitAction cycleWorkspaceStatus decreaseWorkspaceTerminalFontSize devtools.captureFullPageScreenshot
        devtools.captureNodeScreenshot devtools.captureScreenshot devtools.clearConsole devtools.close devtools.copyConsoleLog
        devtools.emptyCacheAndHardReload devtools.openDocked devtools.openDockedLeft devtools.openDockedRight devtools.openInWindow
        devtools.pauseScript devtools.resumeScript devtools.showAnimations devtools.showApplication devtools.showElements
        devtools.showLayers devtools.showLighthouse devtools.showMemory devtools.showNetwork devtools.showPerformance
        devtools.showRendering devtools.showSecurity devtools.showSensors devtools.showSources devtools.takeHeapSnapshot
        devtools.throttleFast3G devtools.throttleOff devtools.throttleOffline devtools.throttleSlow3G devtools.toggleCSS
        devtools.toggleCache devtools.toggleFPSMeter devtools.toggleFocusEmulation devtools.toggleJavaScript devtools.toggleLayerBorders
        devtools.toggleLayoutShiftRegions devtools.togglePaintFlashing devtools.togglePerformanceRecording devtools.toggleReducedMotion
        devtools.viewPageSource diagnostics.viewHangReport diffViewerGoToBottom diffViewerGoToTop diffViewerHalfPageDown
        diffViewerHalfPageUp diffViewerNextFile diffViewerNextHunk diffViewerNextLine diffViewerPreviousFile diffViewerPreviousHunk
        diffViewerPreviousLine diffViewerSearch divider.hide divider.insertNew divider.show duplicateTab editWorkspaceDescription
        equalizeSplits file.openAsPage fileEditorAction fileEditorGotoLine fileEditorReplace fileEditorZoomIn fileEditorZoomOut
        fileEditorZoomReset filePreviewOpenExternally filePreviewOpenWith filePreviewRevealInFiles filePreviewRevealInFinder find
        findInDirectory findNext findPrevious focusBrowserAddressBar focusDown focusLeft focusLocation focusNextPane focusPaneByNumber
        focusPreviousPane focusRight focusTextBoxInput focusUp git.checkpoint.create git.worktree.apply git.worktree.create
        groupSelectedWorkspaces hideFind home.messageAbout importFromBrowser increaseWorkspaceTerminalFontSize inspectBrowserElement
        layout.undo macScreen.open manageLayouts markWorkspaceDone markdownBack markdownForward markdownGoToTop markdownLink
        markdownReload markdownResetTableWidths markdownSave markdownZoomIn markdownZoomOut markdownZoomReset moveSurfaceLeft
        moveSurfaceRight moveSurfaceToNextPane moveSurfaceToPaneDown moveSurfaceToPaneLeft moveSurfaceToPaneRight moveSurfaceToPaneUp
        moveSurfaceToPreviousPane moveWorkspaceDown moveWorkspaceToGroup moveWorkspaceToNewWindow moveWorkspaceToWindow moveWorkspaceUp
        navigate.next navigate.previous neverHibernateSite new.agentChat new.agentChat.columnLeft new.agentChat.columnRight
        new.agentChat.down new.agentChat.left new.agentChat.right new.agentChat.row new.agentChat.tab new.agentChat.up
        new.agentChat.window new.agentChat.workspace new.browser new.browser.columnLeft new.browser.columnRight new.browser.down
        new.browser.left new.browser.right new.browser.row new.browser.tab new.browser.up new.browser.window new.browser.workspace
        new.newTabPage new.newTabPage.columnLeft new.newTabPage.columnRight new.newTabPage.down new.newTabPage.left new.newTabPage.right
        new.newTabPage.row new.newTabPage.tab new.newTabPage.up new.newTabPage.window new.newTabPage.workspace new.terminal
        new.terminal.columnLeft new.terminal.columnRight new.terminal.down new.terminal.left new.terminal.right new.terminal.row
        new.terminal.tab new.terminal.up new.terminal.window new.terminal.workspace newBrowserWorkspace newColumn newColumnLeft
        newFloatingPane newPaneAutoLayout newRow newTab newTab.afterCurrent newTab.atEnd newTab.atStart newTab.horizontal newTab.page
        newTab.submit newTab.toRight newWorkspaceGroup nextSidebarTab nextSidebarTabInGroup nextSurface nextWorkspaceGroup
        notifications.dismissHighlight notifications.previewSound notifications.setGroupSound notifications.setWorkspaceSound
        notifications.toggleWorkspaceMute omnibar.openInBackgroundTab omnibar.openInForegroundTab openFolder openLinkInDefaultBrowser
        palette.addWorkspaceChecklistItem palette.browserOpenDefault palette.browserToggleOmnibar palette.clearTabName
        palette.clearWorkspaceDescription palette.clearWorkspaceName palette.copyIdentifiers palette.copyPaneID palette.copyPaneLink
        palette.copySurfaceID palette.copySurfaceLink palette.copyWorkspaceID palette.copyWorkspaceIDAndRef palette.copyWorkspaceLink
        palette.disableBrowser palette.enableBrowser palette.findWork palette.layout.open palette.markWorkspaceRead
        palette.markWorkspaceUnread palette.moveTabToNewWorkspace palette.moveWorkspaceToTop palette.newAgentChat palette.newSimulatorPane
        palette.openCloudPane palette.openDirectoryDiffViewer palette.openFilesPane palette.openFindPane palette.openFolderInVSCodeInline
        palette.openVaultPane palette.openWorkspacePullRequests palette.openWorkspaceTodoPane palette.resetWorkspaceColor
        palette.swapWithSession palette.terminalOpenDirectory palette.terminalToggleTextBoxInput palette.toggleDictation
        palette.toggleFullWidthTab palette.toggleTabPin palette.toggleTabUnread palette.toggleTerminalChat palette.toggleWorkspacePin
        palette.workspaceColor palette.workspaceStatus pane.clearBackground pane.focus pane.moveToNewWindow pane.moveToNewWorkspace
        pane.screenshot pane.setBackground pane.setTint pane.toggleTabBar pasteLastScreenshot prevSidebarTab prevSidebarTabInGroup
        prevSurface prevWorkspaceGroup reconnectPane reconnectWorkspace reloadTab remote.openBrowserTab remote.openLocalBrowserTab
        remote.openRemote remote.openTerminalHere remote.setQuality removeWorkspaceFromGroup renamePane renameTab renameWorkspace
        reopenClosedBrowserPanel reopenClosedWorkspace reopenPreviousSession resetTerminal resetWorkspaceTerminalFontSize resizePaneDown
        resizePaneLeft resizePaneRight resizePaneUp resumeCommandClear resumeCommandEdit resumeCommandSet revealWorkspaceInFinder
        saveFilePreview saveLayoutTemplate screen.clearColor screen.clearIcon screen.clearName screen.color.blue screen.color.cyan
        screen.color.green screen.color.grey screen.color.orange screen.color.pink screen.color.purple screen.color.red
        screen.color.yellow screen.duplicate screen.focus screen.moveLeft screen.moveRight screen.moveToNewWindow
        screen.moveToNewWorkspace screen.moveToWorkspace screen.new screen.newWith screen.next screen.previous screen.rename screen.select
        screen.selectLast screen.setColor screen.setIcon screen.togglePin screenGroup.addScreen screenGroup.clearIcon screenGroup.collapse
        screenGroup.color.blue screenGroup.color.cyan screenGroup.color.green screenGroup.color.grey screenGroup.color.orange
        screenGroup.color.pink screenGroup.color.purple screenGroup.color.red screenGroup.color.yellow screenGroup.create
        screenGroup.expand screenGroup.moveLeft screenGroup.moveRight screenGroup.moveToNewWindow screenGroup.moveToNewWorkspace
        screenGroup.moveToWorkspace screenGroup.newScreen screenGroup.removeScreen screenGroup.rename screenGroup.save
        screenGroup.setColor screenGroup.setIcon screenGroup.toggleCollapsed screenGroup.ungroup screenGroup.unsave selectSurfaceByNumber
        selectWorkspaceByNumber sendCtrlFToTerminal showBrowserJavaScriptConsole sidebar.revealWorkspace simulatorHome simulatorRotateLeft
        simulatorRotateRight simulatorToggleAppearance simulatorToggleSoftwareKeyboard splitBrowserDown splitBrowserRight splitDown
        splitLeft splitRight splitUp swapPaneDown swapPaneLeft swapPaneRight swapPaneUp tab.clearIcon tab.duplicateToNewSplit tab.focus
        tab.moveToNewColumn tab.moveToNewDockColumn tab.moveToNewSplit tab.moveToNewWindow tab.moveToSpace tab.moveToWindow
        tab.moveToWorkspace tab.muteAudio tab.muteOtherAudio tab.pictureInPicture tab.screenshot tab.search tab.setIcon tab.setTint
        tab.showResources tab.unmuteAudio tabGroup.addTab tabGroup.clearIcon tabGroup.collapse tabGroup.color.blue tabGroup.color.cyan
        tabGroup.color.green tabGroup.color.grey tabGroup.color.orange tabGroup.color.pink tabGroup.color.purple tabGroup.color.red
        tabGroup.color.yellow tabGroup.create tabGroup.deleteSaved tabGroup.expand tabGroup.moveLeft tabGroup.moveRight
        tabGroup.moveToNewColumn tabGroup.moveToNewSplit tabGroup.moveToNewWindow tabGroup.moveToNewWorkspace tabGroup.moveToWorkspace
        tabGroup.newTab tabGroup.removeTab tabGroup.rename tabGroup.reopenSaved tabGroup.save tabGroup.setColor tabGroup.setIcon
        tabGroup.toggleCollapsed tabGroup.ungroup tabGroup.unsave tabs.verticalTabs.collapse tabs.verticalTabs.expandOnHover
        tabs.verticalTabs.toggle terminal.clear terminal.clearTheme terminal.decreaseFontSize terminal.fixLastCommand
        terminal.increaseFontSize terminal.keep terminal.project terminal.resetFontSize terminal.runLastCommandAgain
        terminal.scrollPageDown terminal.scrollPageUp terminal.scrollToBottom terminal.scrollToSelection terminal.scrollToTop
        terminal.selectAll terminal.sendLastOutputToChat terminal.sendSelectionToChat terminal.sendText terminal.setTheme terminalCopy
        terminalPaste toggleBrowserDesignMode toggleBrowserDeveloperTools toggleBrowserFocusMode toggleCanvasLayout
        toggleChecklistItemComplete toggleFileEditorMinimap toggleFileEditorWordWrap toggleFloatingPane
        toggleFocusedWorkspaceGroupCollapsed toggleReactGrab toggleSplitZoom toggleTabAudioMute toggleTerminalCopyMode toggleUnread
        triggerFlash useSelectionForFind wakeTab window.movePaneToDock workspace.clearIcon workspace.clearTheme workspace.copyPath
        workspace.dockBottom workspace.dockLeft workspace.dockRight workspace.dockTop workspace.duplicate workspace.duplicateTerminalsOnly
        workspace.duplicateToSpace workspace.mergeInto workspace.moveAbove workspace.moveBelow workspace.moveToBottom
        workspace.moveToNewGroup workspace.moveToSpace workspace.nameFromActivity workspace.newAbove workspace.newAtBottom
        workspace.newAtTop workspace.newBelow workspace.newInNewGroup workspace.newLikeThis workspace.newOnMachine workspace.selectFirst
        workspace.selectLast workspace.selectLastUsed workspace.setIcon workspace.setRemoteLocalhost workspace.setTheme workspace.setTint
        workspace.showResources workspace.sortByDirectory workspace.sortByLastUsed workspace.sortByName workspace.toggleAudioMute
        workspace.toggleDockFloating workspace.toggleKeepAwake workspace.toggleTop workspace.undock workspace.unpinFromSpace
        workspaceGroup.addToSection workspaceGroup.clearColor workspaceGroup.clearIcon workspaceGroup.clearNotifications
        workspaceGroup.collapse workspaceGroup.collapseOthers workspaceGroup.color.blue workspaceGroup.color.cyan
        workspaceGroup.color.green workspaceGroup.color.grey workspaceGroup.color.orange workspaceGroup.color.pink
        workspaceGroup.color.purple workspaceGroup.color.red workspaceGroup.color.yellow workspaceGroup.copyID workspaceGroup.duplicate
        workspaceGroup.editConfig workspaceGroup.expand workspaceGroup.markRead workspaceGroup.markUnread workspaceGroup.moveDown
        workspaceGroup.moveToBottom workspaceGroup.moveToNewWindow workspaceGroup.moveToSpace workspaceGroup.moveToTop
        workspaceGroup.moveToWindow workspaceGroup.moveUp workspaceGroup.newSubgroup workspaceGroup.newWorkspace workspaceGroup.rename
        workspaceGroup.setAutoArchive workspaceGroup.setColor workspaceGroup.setIcon workspaceGroup.setSort workspaceGroup.sortByDirectory
        workspaceGroup.sortByLastUsed workspaceGroup.sortByName workspaceGroup.togglePin workspaceGroup.ungroup
        """)

    /// Reviewed 2026-11-18 (621 actions).
    static let unaffected = ids("""
        about accounts.connect accounts.githubConnect accounts.reauthenticate accounts.refresh accounts.remove accounts.show
        agent.harness.add agent.harness.addFromRegistry agent.harness.doctor agent.harness.remove agent.harness.restore
        agent.harness.setIcon agent.harness.updateAll agent.jumpToNextNeedingInput agent.openSessionWorkspace agent.share.kick
        agent.share.revoke agentActivity.open agentBoard.show agentChat.view agentPane.display.railOnRight agentPane.display.showMinimap
        agentPane.searchChats agentPane.stopReadingAloud agentPane.togglePointerInspector announcements.hide announcements.show
        app.command.run app.hide app.install app.open app.reloadCustomViews app.remove app.shareCmux app.try.run app.try.undo app.unhide
        appStore.show appStore.showInstalled appearance.animationSpeed.fast appearance.animationSpeed.normal appearance.animationSpeed.off
        appearance.animations.cursor.toggle appearance.animations.feedback.toggle appearance.animations.home.toggle
        appearance.animations.hoverCards.toggle appearance.animations.indicators.toggle appearance.animations.newTab.toggle
        appearance.animations.newWorkspace.toggle appearance.animations.overlays.toggle appearance.animations.panes.toggle
        appearance.animations.sidebar.toggle appearance.animations.tabs.toggle appearance.animations.toggle
        appearance.animations.web.toggle appearance.chromeStyle.bare appearance.chromeStyle.blocks appearance.chromeStyle.card
        appearance.chromeStyle.cardOutlined appearance.chromeStyle.default appearance.chromeStyle.flat
        appearance.chromeStyle.flatSidebarLine appearance.chromeStyle.floating appearance.chromeStyle.panes appearance.chromeStyle.twoTone
        appearance.customize appearance.density.comfortable appearance.density.compact appearance.density.cozy appearance.density.create
        appearance.density.set appearance.density.spacious appearance.density.ultraCompact appearance.glass.lens.toggle
        appearance.interfaceSize.decrease appearance.interfaceSize.increase appearance.interfaceSize.reset appearance.paneBorder.toggle
        appearance.paneBorderColor.reset appearance.paneBorderWidth.toggle appearance.paneCorners.toggle appearance.panePadding.toggle
        appearance.personalize appearance.titlebar.minimal appearance.titlebar.standard appearance.uiScale.decrease
        appearance.uiScale.increase appearance.uiScale.reset artifacts.show attention.goTo automations.show billing.openPortal
        bookmark.add bookmark.export bookmark.import bookmark.importFromBrowser bookmark.manager bookmark.newFolder bookmark.toggleBar
        browser.defaultEngine.chromium browser.defaultEngine.webkit browser.download.openBlockedSiteSettings browser.downloads.showFolder
        browser.hibernation.aggressive browser.hibernation.moderate browser.hibernation.off browser.importCookies browser.importFromFiles
        browser.keepNeighborTabsAwake.0 browser.keepNeighborTabsAwake.1 browser.keepNeighborTabsAwake.2 browser.keepNeighborTabsAwake.3
        browser.showCookieImportBanner browser.toolbar.togglePin browserProfile.clearColor browserProfile.clearIcon
        browserProfile.clearProxy browserProfile.move browserProfile.new browserProfile.newWindow browserProfile.newWorkspace
        browserProfile.rename browserProfile.setColor browserProfile.setIcon browserProfile.setProxy browserShowHistory
        chief.importMemories chief.importMemories.undo chief.moveRollback chief.moveTo chief.openMemoryInspector chief.openSubagent
        chief.openUsage chief.openViews chief.screenShare.look chief.screenShare.start chief.screenShare.stop chief.screenShare.toggle
        chief.toggleMemoryInspector clearAllNotifications closeAllWindows closed.clear closed.delete cloud.group.memberRemove
        cloud.group.memberSet cloud.group.members cloud.secret.remove cloud.team.members cloud.team.sessions cloud.team.showSection
        cloudAPIKeyList cloudAPIKeyRevoke cloudApplyMachineConfig cloudCopyLink cloudCopyMachineID cloudCopyPort cloudDeliverSecrets
        cloudDiagnostics cloudDomainList cloudExec cloudFileMkdir cloudFileRead cloudFileStat cloudFileWrite cloudFilesList
        cloudFirewallCreate cloudFirewallDelete cloudFirewallGet cloudFirewallList cloudListMachines cloudMachineLink cloudNetworkList
        cloudNewTerminal cloudOpenBrowser cloudOpenDesktop cloudOpenMachine cloudPortForward cloudPortList cloudPrepareSCP
        cloudPreviewShare cloudProvisionAPI cloudPublicationList cloudRenameMachine cloudResizeMachine cloudResumeMachine cloudSSH
        cloudSetIdlePause cloudSetNetworkAccess cloudSetupDesktop cloudSetupGitHub cloudStartSession cloudTunnelAttach cloudTunnelDetach
        cloudTunnelRotateKey commandPalette commandPaletteNext commandPalettePrevious computerUseFocus computerUseFocusCallingTerminal
        computerUseStop customize.library.reset customize.open debug.actionLatencyHUD debug.allThemesPlayground debug.autoArchive.age
        debug.blockingCalls.copy debug.blockingCalls.reset debug.densityOverlayPlayground debug.keycapPlayground debug.projection
        debug.projection.runTest debug.sidebarRowTuner debug.sidebarStatesPlayground debug.sidebarToggleIcon debug.statusIconSet
        debug.tabBarPlayground debug.toastPlayground debug.toastTuning debug.viewWindow device.add errors.clear feed.githubAction
        feed.openItem file.openRecoveredDraft fileEditor.importEditorSettings fileExplorerCopyPath fileExplorerCopyRelativePath
        fileExplorerNewFile fileExplorerNewFolder fileExplorerOpenAsText fileExplorerOpenInCmux fileExplorerOpenSelection
        fileExplorerOpenSelectionFinderAlias fileExplorerOpenWith fileExplorerRename fileExplorerReveal files.open focusHistoryBack
        focusHistoryForward focusHistoryLast focusRing.singlePane.toggle focusRing.style.glow focusRing.style.ring focusRing.toggle
        gallery.openStage ghostty.showDiagnostics globalSearch goToWorkspace help.copyLogs help.discord help.documentation
        help.featureFlags help.followOnX help.github help.revealLogs help.showCrashLogs help.troubleshooting hints.show history.clear
        history.commands history.goTo history.open history.removeSite history.reopen history.resumeAgentSession history.search
        history.show home.addMembers home.agentMessagePlayground home.archiveChief home.attachFiles home.channels home.chatColors
        home.chiefTeleportPlayground home.closeNewMessage home.compareTablePlayground home.conversationInfo home.createChannel
        home.createGroup home.deleteChief home.disableChannels home.enableChannels home.hideConversation home.invite home.inviteToTeam
        home.leaveConversation home.mcpConnectPlayground home.messageChiefFromAnyApp home.messageChiefPet home.messageTo
        home.muteConversation home.newChief home.newMessage home.nextConversation home.openChief home.openConversation
        home.previousConversation home.removeMember home.renameConversation home.replyToSelection home.saveFlightRecording
        home.selectConversationByNumber home.sendMessage home.sendSelectionTo home.sendSelectionToChief home.setChiefReplies
        home.setPrimaryChief home.show home.showHiddenConversations home.showHideChiefFromAnyApp home.startQueuedAgent home.switchView
        home.tab home.toggleChiefPet home.toggleChiefSettings home.togglePin home.unmuteConversation home.zoomIn home.zoomOut
        home.zoomReset hostPressure.hideWarning hostPressure.showWarning import.card import.list import.open import.suggest
        jumpToLastPrompt jumpToUnread keepMacAwake keybindings.open layout.centerFocusedColumn.always layout.centerFocusedColumn.never
        layout.centerFocusedColumn.onOverflow layout.toggleStripScrollbar link.open links.openInCmuxBrowser links.openInDefaultBrowser
        links.signInPagesByLinkSettings links.signInPagesInCmux list.next list.previous liveSwift.start liveSwift.stop liveWeb.start
        liveWeb.stop macScreen.deviceAccess macScreen.revokeViewer macScreen.shareThisMac macScreen.stopSharing
        macScreen.stopSharingThisMac machine.add machine.clearIcon machine.doctor machine.joined.check machine.joined.rotate
        machine.reconnect machine.setIcon markAllNotificationsRead markOldestUnreadAndJumpNext music.open music.stop newCloudMachine
        newCloudWorkspace newIncognitoWindow newWindow notificationCopy notificationDismiss notificationOpen notificationToggleRead
        notifications.allowDesktop notifications.dismissal.click notifications.dismissal.explicit notifications.dismissal.focus
        notifications.dismissal.keystroke notifications.dismissal.never notifications.dismissal.timeout notifications.importSound
        notifications.setAgentSound notifications.setEventSound notifications.toggleBanners nowPlaying.disableCard nowPlaying.hideCard
        nowPlaying.hideCardUntilRelaunch nowPlaying.playPause nowPlaying.showCard openDebugSettings openSettings openTeamPicker
        palette.addHarness palette.applyUpdateIfAvailable palette.attemptUpdate palette.auth.signIn palette.auth.signOut
        palette.captureScreenshotToChat palette.checkForUpdates palette.clearSearchHistory palette.cloud.fork palette.cloud.handoff
        palette.cloud.ports palette.cloud.promoteTemplate palette.cloud.restore palette.cloud.snapshot palette.cloud.status
        palette.cloud.tools palette.computerUse.accessibility palette.computerUse.restart palette.computerUse.screenRecording
        palette.computerUse.setup palette.disableMinimalMode palette.enableMinimalMode palette.forkAgentConversation
        palette.forkAgentConversationBottom palette.forkAgentConversationLeft palette.forkAgentConversationNewColumnLeft
        palette.forkAgentConversationNewColumnRight palette.forkAgentConversationNewRow palette.forkAgentConversationNewTab
        palette.forkAgentConversationNewWindow palette.forkAgentConversationNewWorkspace palette.forkAgentConversationRight
        palette.forkAgentConversationTo palette.forkAgentConversationTop palette.installCLI palette.launchClaudeTeams
        palette.launchCodexTeams palette.makeDefaultBrowser palette.makeDefaultTerminal palette.mobileConnect palette.newAgentChatOn
        palette.newCloudChat palette.open palette.openCmuxSettingsFile palette.openGhosttySettings palette.openTaskManager
        palette.openTerminalChatView palette.pro.upgrade palette.quickAgentChat palette.restartServer palette.restartSocketListener
        palette.searchShortcuts palette.shortcutKeymap palette.sleepyMode palette.startAgentFromAnyApp palette.switchAppChannel
        palette.toggleMatchTerminalBackground palette.toggleSetting palette.uninstallCLI paletteKey.back paletteKey.closeActions
        paletteKey.closeItem paletteKey.enterRow paletteKey.escape paletteKey.filterDeleteBackward paletteKey.firstItem
        paletteKey.lastItem paletteKey.leaveLevel paletteKey.openActions paletteKey.pageDown paletteKey.pageUp paletteKey.submit
        paletteKey.submitAlternate paletteKey.toggleActions password.importCSV passwords.open phone.appearance phone.boot phone.button
        phone.install phone.launch phone.list phone.locale phone.location phone.logs phone.openURL phone.paste phone.recordStart
        phone.recordStop phone.rotate phone.screenshot phone.sendFeedback phone.show phone.shutdown phone.swipe phone.tap phone.type
        phone.ui quit quitEndEverything quitEndSessions quitKeepSessions recentlyClosed recentlyFocused reloadConfiguration
        remote.allowAccessibility remote.allowScreenRecording remote.connect remote.copyError remote.newGroup remote.newWorkspace
        remote.reconnect remote.refreshPermissions remote.restartComputerUse remote.restartScreenSharing remote.showStatus
        remote.stopScreenSession screen.reopenClosed screenGroup.deleteSaved screenGroup.reopenSaved screenshots.open search.chats
        selectNextWindow selectPreviousWindow sendFeedback server.addServer server.makeThisMacAServer server.pairAnotherMachine
        server.showHealth server.showPanel server.stopServing session.moveFromBuild settings.customizeMenus showHideAllWindows
        showMainWindow showNotifications sidebar.chat.togglePin sidebar.chief.toggleIdleSubagents sidebar.compactList.toggle
        sidebar.controlsOnHover.off sidebar.controlsOnHover.on sidebar.custom.toggle sidebar.customize sidebar.density.comfortable
        sidebar.density.compact sidebar.density.expanded sidebar.edit sidebar.floatOnHover.off sidebar.floatOnHover.on
        sidebar.groupBy.folder sidebar.groupBy.none sidebar.home.add sidebar.home.remove sidebar.item.add sidebar.item.hideApp
        sidebar.item.toggleLabel sidebar.layout.reset sidebar.noFade.off sidebar.noFade.on sidebar.priority.markRead
        sidebar.priority.moveEarlier sidebar.priority.moveLater sidebar.priority.snooze sidebar.priority.togglePin
        sidebar.priorityView.toggle sidebar.profileControl.hide sidebar.profileControl.show sidebar.profileMenu sidebar.projects.hide
        sidebar.revealAndFocusWorkspace sidebar.section.add sidebar.section.hide sidebar.section.layoutGrid sidebar.section.layoutInline
        sidebar.section.layoutList sidebar.section.moveToScrolling sidebar.section.moveToTop sidebar.section.newWorkspace
        sidebar.section.rename sidebar.section.setAlignment sidebar.section.setColumns sidebar.section.setGap sidebar.section.setMaxRows
        sidebar.section.toggleCollapsed sidebar.section.toggleSpaceScope sidebar.section.toggleTitle sidebar.section.useBuiltInLook
        sidebar.section.useListLook sidebar.sections.showHidden sidebar.spaces.show space.new space.newIncognito space.next space.previous
        stash.importOneTab stash.show stats.show tabs.overflow.scroll tabs.overflow.shrink tabs.toolbar.togglePin
        tabs.verticalTabs.allWorkspaces taskManager.killProcess tasks.new tasks.show tasks.showMine tips.muteDay tips.muteWeek
        toasts.showHidden toggleQuickTerminal updates.cancelDownload updates.installEarlierBuild updates.releaseNotes updates.rollback
        updates.showDetails updates.snooze updates.whatsNew vaultCopyResumeCommand vaultFocusSession vaultOpenPullRequest vaultOpenSession
        vaultResumeInNewWorkspace voiceRoom.open voiceRoom.stop window.screenshot workspace.archiveIdle workspace.closeAllInAllWindows
        workspace.importClassic workspace.removeAllColors workspace.restoreArchived workspaceGroup.collapseAll workspaceGroup.expandAll
        zoomWindow
        """)

    private static func ids(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }
}

import AppKit
import CmuxNextDesign
import CmuxNextCompat
import Observation
extension SidebarViewComponents {
    // MARK: Observation
    /// Everything the list renders. Emitting a value type lets the list
    /// skip reloads when an unrelated model property changes.
    struct RenderState: Hashable, Sendable {
        /// `SidebarModel.structureRevision`: a structural change, compared
        /// instead of every row (a row content change patches its row; a
        /// group's fold splices its rows through `onGroupFolded`).
        var sectionsRevision: UInt64
        var selection: Set<WorkspaceID>
        var selected: SidebarItem?
        /// `SidebarModel.onScreen` while `sidebar.multiView` is on: a change repaints the rows' fills only.
        var onScreen: Set<WorkspaceID>
        var profiles: [SidebarProfile]
        var activeProfile: ProfileKey?
        var filter: String
        var layout: SidebarLayoutDocument
        var itemInfo: [LayoutItemID: SidebarItemInfo]
        var transientTopItems: [SidebarTransientItem]
        var collapsedSections: Set<LayoutSectionID>
        var look: SectionsLookVariant
        var drawsLines: Bool
        var preferences: SidebarSectionsPreferences
        var suppressedApps: Set<String>
        /// Design tokens (density, overrides, chrome font size). Reading them
        /// inside the tracked closure makes a settings change re-render.
        var metrics: SidebarLayoutMetrics
        var fontSize: CGFloat
        var titlebarHeight: CGFloat
        var cards: SidebarBottomCards
        /// The session tree (`sidebar.sessionTree`): nesting, pull requests, keycaps.
        var tree: SidebarSessionTreeState?
        /// Every row's pull request badge, tree or not.
        var pullRequests: [WorkspaceID: SidebarPullRequestBadge]
        /// The session tree's chat history: Pinned and Earlier.
        var history: SidebarChatHistoryState?
        /// Workspaces as tabs (`SidebarTunables.workspacesAsTabs`): one-line rows.
        var workspacesAsTabs: Bool
        /// Group by Status (`SidebarTunables.groupByStatus`, Debug, off by default).
        var groupsByStatus: Bool
        /// The row limit (`SidebarTunables.groupRowLimit`): changing it lays the list out again.
        var rowLimit: Int
        /// Where group lines sit (`sidebar.groupLineLayout`): headers reach and lines move, so the list lays out again.
        var groupLineLayout: SidebarGroupLineLayout
        var groupChromeShape: Bool
        /// Whether a joined line runs out of its header's bar (`SidebarGroupLine.joinsBar`, the band header style)
        /// or starts after the cut: its frame moves, so the list lays out again.
        var groupLineJoinsBar: Bool
        /// Whether a group with no color draws its block (`sidebar.noColorGroup` not plain) or nothing: the
        /// group's line view changes kind, so the list lays out again.
        var noColorBlocks: Bool
        /// Where leading glyphs sit in the icon column (`sidebar.leadingColumn`): every row lays out again.
        var leadingColumn: SidebarLeadingColumnLook
        /// One list's "Workspaces" heading (`sidebar.listHeading`): the list lays out again with or without it.
        var listHeading: Bool
        /// What a pinned row with its own icon leads with (`sidebar.pinnedRowLeading`): every row lays out again.
        var pinnedRowLeading: SidebarPinnedRowLeading
        /// Every token the titlebar row's width reads past the view's own inputs (the reserve, the accessory, the
        /// Priority bell, which refresh it themselves): the button, the +'s trailing inset (the trailing column at
        /// the app and sidebar density), the toolbar band's button (the reserve's source), the traffic lights'
        /// inset and the gaps. A change refreshes
        /// `SidebarModel.titlebarControlsWidth`, so the minimum width never keeps an old density's.
        var titlebarRow: [CGFloat]
        /// The space switcher's own tokens (the slot, the dot and the small icon; Debug Settings changes them). No other
        /// state has them, and the switcher no longer follows every layout, so a change marks the bands (`bandsDirty`).
        var switcherTokens: [CGFloat]
        /// What places the window top's line with no view moving or resizing: its variant (Debug Settings
        /// `chrome.topRowLine`), the titlebar style, the tab bars' edge and what the card's reach reads (#38054). Every window has a sidebar, so it lays
        /// its window out again on a change, with or without a top-row tab strip; moves reach the strips through
        /// `TabStripView.updateWindowControlsAvoidance`.
        var topRow: [String]
        init(_ model: SidebarModel, _ design: DesignSettings) {
            sectionsRevision = model.observedStructureRevision
            selection = model.selection
            selected = model.selectedItem
            onScreen = SidebarTunables.multiViewOn ? model.onScreen : []
            profiles = model.profiles
            activeProfile = model.activeProfileID
            filter = model.filterText
            layout = model.layout
            itemInfo = model.resolvedItemInfo
            transientTopItems = model.transientTopItems
            collapsedSections = model.collapsedLayoutSections
            look = SidebarSectionTunables.currentLook
            drawsLines = Borders.drawsLines
            preferences = design.sidebarSections
            suppressedApps = model.suppressedApps
            metrics = .standard
            fontSize = SidebarStyle.titleFont.pointSize
            titlebarHeight = Metrics.titlebarHeight
            cards = SidebarBottomCards(update: model.updateCard, nowPlaying: model.nowPlaying, updated: model.updatedCard, notice: model.noticeCard)
            tree = SidebarSessionTree.shared.drawn
            pullRequests = SidebarSessionTree.shared.pullRequests
            history = SidebarChatHistory.shared.state
            workspacesAsTabs = SidebarTunables.workspacesAsTabsOn
            groupsByStatus = SidebarTunables.groupByStatus.value
            rowLimit = SidebarTunables.rowLimit
            groupLineLayout = SidebarGroupLineLayout.tunable.value
            groupChromeShape = SidebarStyle.groupChromeShape
            groupLineJoinsBar = SidebarGroupLine.joinsBar
            noColorBlocks = SidebarNoColorGroupLook.tunable.value != .plain
            leadingColumn = SidebarLeadingColumnLook.tunable.value
            listHeading = SidebarTunables.listHeading.value
            pinnedRowLeading = SidebarPinnedRowLeading.tunable.value
            titlebarRow = [SidebarStyle.toolbarButtonSize, SidebarStyle.titlebarPlusTrailingInset, TitlebarBandButton.side,
                           Metrics.trafficLightInset, Metrics.space1, Metrics.space2, Metrics.space3]
            switcherTokens = [Metrics.roomDotSlot, Metrics.roomDotDiameter, Metrics.smallIconSize]
            // The line also follows the card's reach (#38054): the gutter, the pane padding, floating panes and the strip's tokens.
            topRow = [TopRowLineLook.tunable.value.rawValue, "\(DesignSettings.shared.titlebar)", "\(DesignSettings.shared.tabBarPosition)",
                      "\(Metrics.mainPaneGutter)", "\(Metrics.panePadding)", "\(Metrics.floatingPanes)", "\(Metrics.tabStripHeight)",
                      "\(Metrics.tabHeight)"]
        }
    }
    func observe() {
        let model = model, design = design
        observation = Task { [weak self] in
            // A trigger: `renderNow` draws outside the stream; `render` compares with what it drew.
            for await state in ObservationStream({ ObservationTrigger(RenderState(model, design)) }) { self?.render(state.value) }
        }
    }
    /// Draws the model now, in the caller's turn (SidebarSameTurn); the observation's next, equal state is skipped.
    public func renderNow() { render(RenderState(model, design)) }

    /// Draws the model in this turn's frame: the main run loop's block phase, before AppKit's display cycle and the
    /// commit, once however many times the turn asks. An input's turn changes the model and leaves the view work to
    /// the frame that shows it (Cmd-N's row, SWITCH STALL 6); a later `renderNow` in the turn draws it first.
    public func renderInFrame() {
        guard !renderQueued else { return }
        renderQueued = true
        MainRunLoopBlock.perform { [weak self] in
            self?.renderQueued = false
            self?.renderNow()
        }
    }

    /// Draws the model now and scrolls the selection into view, with the header
    /// and list top around it, even when it did not change: Cmd-`n`, Cmd-Ctrl-[ / ]
    /// and the palette pressed again on the item they already selected.
    public func revealSelection() {
        renderNow()
        list.revealSelectionNow()
    }
    func render(_ state: RenderState) {
        guard state != lastState else { return }
        let chromeChanged = lastState?.metrics != state.metrics || lastState?.fontSize != state.fontSize
            || lastState?.titlebarHeight != state.titlebarHeight || lastState?.leadingColumn != state.leadingColumn
            || lastState?.pinnedRowLeading != state.pinnedRowLeading
        if lastState?.titlebarRow != state.titlebarRow {
            // The window root sets the reserve from the toolbar band, whose width follows the same tokens.
            window?.contentView?.needsLayout = true
            titlebarReserveChanged()
        }
        if let last = lastState, last.topRow != state.topRow, let window { WindowTitlebar.layOutTopRowAgain(in: window) }
        let profileChanged = lastState?.activeProfile != state.activeProfile
        let profilesChanged = lastState?.profiles != state.profiles || profileChanged
            || lastState?.layout != state.layout || lastState?.itemInfo != state.itemInfo
            || lastState?.transientTopItems != state.transientTopItems
            || lastState?.collapsedSections != state.collapsedSections || lastState?.look != state.look
            || lastState?.drawsLines != state.drawsLines || lastState?.preferences != state.preferences || lastState?.suppressedApps != state.suppressedApps
        let selectionChanged = lastState?.selection != state.selection || lastState?.selected != state.selected
        let rowsChanged = lastState?.sectionsRevision != state.sectionsRevision || lastState?.filter != state.filter || chromeChanged || profileChanged
            || state.preferences.changesList(from: lastState?.preferences) || lastState?.tree != state.tree
            || lastState?.history != state.history
            || lastState?.workspacesAsTabs != state.workspacesAsTabs
            || lastState?.groupsByStatus != state.groupsByStatus
            || lastState?.rowLimit != state.rowLimit || lastState?.groupLineLayout != state.groupLineLayout
            || lastState?.groupChromeShape != state.groupChromeShape
            || lastState?.groupLineJoinsBar != state.groupLineJoinsBar || lastState?.noColorBlocks != state.noColorBlocks
        let listChanged = rowsChanged || selectionChanged
        // A selected session never hides in a fold (a notification, the palette or Cmd-number chose it).
        if selectionChanged { state.selection.forEach(SidebarSessionTree.shared.reveal) }
        let previous = lastState == nil ? nil : lastSections
        model.applyListPreferences(state.preferences)
        model.groupByStatus(state.groupsByStatus)
        // Minimal mode or an item's control changed: show or hide the chosen bands now.
        // Controls on hover too (`sidebar.controlsOnHover`): its controls fade to the new rule.
        if lastState?.preferences.minimalMode != state.preferences.minimalMode || lastState?.itemInfo != state.itemInfo
            || lastState?.preferences.controlsOnHover != state.preferences.controlsOnHover {
            setChromeRevealed(isChromeRevealed)
        }
        // A selected top item (a workspace's tile, a band item) repaints only itself and the one before it;
        // before any reload below, so a block it configures draws the new selection.
        if lastState?.selected != state.selected || lastState?.selection != state.selection { showActiveTopItem() }
        // A document change (a drop) moves the list's rows and its blocks together: the blocks update now, not at
        // the next layout pass, so the list reloads once with both (ptr8: a settle on the rows alone showed the
        // stale blocks for a frame: the dragged tile back in Pinned, the rows bumped, the card aimed 24 pt off).
        if listChanged, profilesChanged, !profileChanged, model.docDrag != nil, list.settling != nil || list.landing != nil { updateBands(reloadsList: false) }
        // A space switch too: the new space's blocks (its Home, its pinned workspaces) come with its rows. At the
        // next layout pass they were a second change of the list: a second full layout that moved every row on a
        // spring after a click, or one that waited for the pointer to leave the rows after a key.
        if lastState != nil, profileChanged, model.docDrag != nil { updateBands(reloadsList: false) }
        if listChanged {
            if profileChanged {
                showSpace(leaving: lastState?.activeProfile, entering: state.activeProfile)
            } else if selectionChanged, rowsChanged, !model.followsUserIntent, list.showsSelectionRow,
                      list.patchSelection(from: lastState?.selected, oldSelection: lastState?.selection ?? []) {
                // A click moves no row (Leo 2026-10-20): it draws its selection, and rows that changed with it
                // wait under the pointer like any change nobody asked for.
                if list.showModelChange(animates: false) { SidebarNewRowTimer.shared.drew(model.sections, in: window) }
            } else if selectionChanged, rowsChanged || !list.patchSelection(from: lastState?.selected, oldSelection: lastState?.selection ?? []) {
                // A new selection shows now, wherever the pointer is (it is the user's, or asks to be seen).
                list.reload(animated: Self.animatesReload(from: previous, to: model.sections) && model.followsUserIntent, fromModel: true)
                if rowsChanged { SidebarNewRowTimer.shared.drew(model.sections, in: window) }
            } else if rowsChanged {
                // Only a change the user asked for moves rows; others show in place, after the pointer leaves (calm-sidebar-movement).
                if list.showModelChange(animates: Self.animatesReload(from: previous, to: model.sections)) {
                    SidebarNewRowTimer.shared.drew(model.sections, in: window)
                }
            }
            lastSections = model.sections
        }
        // A badge change (a pull request read landed) patches the rows whose badge changed, as a status does; the list
        // is laid out again only when one's height changes (it laid out all 500 rows per answer: sidebar-lag-DESIGN.md).
        if let last = lastState, last.pullRequests != state.pullRequests, !listChanged {
            let ids = Set(last.pullRequests.keys).union(state.pullRequests.keys).filter { last.pullRequests[$0] != state.pullRequests[$0] }
            let rows = ids.compactMap { list.workspaces[$0] }
            if !rows.isEmpty { list.patchRows(rows) }
        }
        if lastState?.onScreen != state.onScreen { list.syncRowStates() }
        if listChanged || lastState?.tree != state.tree { refreshNeedsYou() }
        if lastState?.cards != state.cards { cardSlot.show(state.cards); needsLayout = true }
        if chromeChanged || profilesChanged || lastState?.switcherTokens != state.switcherTokens { bandsDirty = true; needsLayout = true }
        lastState = state
    }
    /// Whether a sections change animates its rows. Provisional rows swap in place.
    static func animatesReload(from old: [SidebarSection]?, to new: [SidebarSection]) -> Bool {
        !new.contains(where: \.hasProvisionalRows) && !(old ?? []).contains(where: \.hasProvisionalRows)
    }
}

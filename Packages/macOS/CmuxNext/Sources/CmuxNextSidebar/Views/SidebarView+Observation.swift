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
        init(_ model: SidebarModel, _ design: DesignSettings) {
            sectionsRevision = model.observedStructureRevision
            selection = model.selection
            selected = model.selectedItem
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
            fontSize = Typography.body.pointSize
            titlebarHeight = Metrics.titlebarHeight
            cards = SidebarBottomCards(update: model.updateCard, nowPlaying: model.nowPlaying, updated: model.updatedCard, notice: model.noticeCard)
            tree = SidebarSessionTree.shared.drawn
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
            || lastState?.titlebarHeight != state.titlebarHeight
        let profileChanged = lastState?.activeProfile != state.activeProfile
        let profilesChanged = lastState?.profiles != state.profiles || profileChanged
            || lastState?.layout != state.layout || lastState?.itemInfo != state.itemInfo
            || lastState?.transientTopItems != state.transientTopItems
            || lastState?.collapsedSections != state.collapsedSections || lastState?.look != state.look
            || lastState?.drawsLines != state.drawsLines || lastState?.preferences != state.preferences || lastState?.suppressedApps != state.suppressedApps
        let selectionChanged = lastState?.selection != state.selection || lastState?.selected != state.selected
        let rowsChanged = lastState?.sectionsRevision != state.sectionsRevision || lastState?.filter != state.filter || chromeChanged || profileChanged
            || state.preferences.changesList(from: lastState?.preferences) || lastState?.tree != state.tree
        let listChanged = rowsChanged || selectionChanged
        // A selected session never hides in a fold (a notification, the palette or Cmd-number chose it).
        if selectionChanged { state.selection.forEach(SidebarSessionTree.shared.reveal) }
        let previous = lastState == nil ? nil : lastSections
        model.applyListPreferences(state.preferences)
        // Minimal mode or an item's control changed: show or hide the chosen bands now.
        if lastState?.preferences.minimalMode != state.preferences.minimalMode || lastState?.itemInfo != state.itemInfo {
            setChromeRevealed(isChromeRevealed)
        }
        // A selected top item (a workspace's tile, a band item) repaints only itself and the one before it;
        // before any reload below, so a block it configures draws the new selection.
        if lastState?.selected != state.selected { showActiveTopItem() }
        // A document change (a drop) moves the list's rows and its blocks together: the blocks update now, not at
        // the next layout pass, so the list reloads once with both (ptr8: a settle on the rows alone showed the
        // stale blocks for a frame: the dragged tile back in Pinned, the rows bumped, the card aimed 24 pt off).
        if listChanged, profilesChanged, !profileChanged, model.docDrag != nil, list.settling != nil || list.landing != nil { updateBands(reloadsList: false) }
        if listChanged {
            if profileChanged {
                switchSpace(from: lastState?.activeProfile, to: state.activeProfile, profiles: state.profiles, oldSections: previous ?? [])
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
        if listChanged || lastState?.tree != state.tree { refreshNeedsYou() }
        if lastState?.cards != state.cards { cardSlot.show(state.cards); needsLayout = true }
        if chromeChanged || profilesChanged { bandsDirty = true; needsLayout = true }
        lastState = state
    }
    /// Whether a sections change animates its rows. Provisional rows swap in place.
    static func animatesReload(from old: [SidebarSection]?, to new: [SidebarSection]) -> Bool {
        !new.contains(where: \.hasProvisionalRows) && !(old ?? []).contains(where: \.hasProvisionalRows)
    }
}

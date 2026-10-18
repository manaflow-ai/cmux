import AppKit
import CmuxNextDesign
import CmuxNextCompat
import Observation
extension SidebarView {
    // MARK: Observation
    /// Everything the list renders. Emitting a value type lets the list
    /// skip reloads when an unrelated model property changes.
    struct RenderState: Hashable, Sendable {
        /// `SidebarModel.sectionsRevision`: a structural change, compared
        /// instead of every row (a row content change patches its row).
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
        init(_ model: SidebarModel, _ design: DesignSettings) {
            sectionsRevision = model.observedSectionsRevision
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
        }
    }
    func observe() {
        let model = model, design = design
        observation = Task { [weak self] in
            for await state in ObservationStream({ RenderState(model, design) }) { self?.render(state) }
        }
    }
    /// Draws the model now, in the caller's turn (SidebarSameTurn); the observation's next, equal state is skipped.
    public func renderNow() { render(RenderState(model, design)) }
    func render(_ state: RenderState) {
        guard state != lastState else { return }
        let chromeChanged = lastState?.metrics != state.metrics || lastState?.fontSize != state.fontSize
            || lastState?.titlebarHeight != state.titlebarHeight
        let profileChanged = lastState?.activeProfile != state.activeProfile
        let profilesChanged = lastState?.profiles != state.profiles || profileChanged
            || lastState?.layout != state.layout || lastState?.itemInfo != state.itemInfo || lastState?.selected != state.selected
            || lastState?.transientTopItems != state.transientTopItems
            || lastState?.collapsedSections != state.collapsedSections || lastState?.look != state.look
            || lastState?.drawsLines != state.drawsLines || lastState?.preferences != state.preferences || lastState?.suppressedApps != state.suppressedApps
        let listChanged = lastState?.sectionsRevision != state.sectionsRevision || lastState?.selection != state.selection
            || lastState?.selected != state.selected || lastState?.filter != state.filter || chromeChanged || profileChanged
            || state.preferences.changesList(from: lastState?.preferences)
        let previous = lastState == nil ? nil : lastSections
        model.applyListPreferences(state.preferences)
        // Minimal mode or an item's control changed: show or hide the chosen bands now.
        if lastState?.preferences.minimalMode != state.preferences.minimalMode || lastState?.itemInfo != state.itemInfo {
            setChromeRevealed(isChromeRevealed)
        }
        // A document change (a drop) moves the list's rows and its blocks together: the blocks update now, not at
        // the next layout pass, so the list reloads once with both (ptr8: a settle on the rows alone showed the
        // stale blocks for a frame: the dragged tile back in Pinned, the rows bumped, the card aimed 24 pt off).
        if listChanged, profilesChanged, !profileChanged, model.docDrag != nil, list.settling != nil || list.landing != nil { updateBands(reloadsList: false) }
        if listChanged {
            if profileChanged {
                switchSpace(from: lastState?.activeProfile, to: state.activeProfile, profiles: state.profiles, oldSections: previous ?? [])
            } else {
                list.reload(animated: Self.animatesReload(from: previous, to: model.sections))
            }
            lastSections = model.sections
        }
        if showsPriority { priorityView.reload() }
        if lastState?.cards != state.cards { cardSlot.show(state.cards); needsLayout = true }
        if chromeChanged || profilesChanged { bandsDirty = true; needsLayout = true }
        lastState = state
    }
    /// Whether a sections change animates its rows. Provisional rows swap in place.
    static func animatesReload(from old: [SidebarSection]?, to new: [SidebarSection]) -> Bool {
        !((old ?? []) + new).contains(where: \.hasProvisionalRows)
    }
}

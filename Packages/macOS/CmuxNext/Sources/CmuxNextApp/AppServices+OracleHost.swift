#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextOracle
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTerminal
import CmuxNextTerminalFind
import CmuxNextWakeups
import CryptoKit
import Foundation

/// The app's `debug.oracle.snapshot` facet providers, DEV and bench builds only: a Release build compiles neither
/// this conformance nor any provider in the list. Only the overlays facet stays (the Chromium Host find rows read
/// its `findBar`); the refactor oracle's other facets were removed in deletion wave 1.
extension AppServices: OracleHost {
    func makeOracleFacets() -> OracleFacets {
        OracleFacets([
            // The overlay hosts, focus overlays, palette, hover card and find bars; their owners signal changes.
            OracleOverlaysFacet(hash: Self.oracleSHA256, changes: { [overlayChanges] in overlayChanges.subscribe() }) { [weak self] in
                self?.oracleOverlays()
            },
        ])
    }

    /// `debug.oracle.snapshot` over the app's one facet list; `AppControl` registers it.
    @MainActor
    func oracleControlMethods() -> [ControlMethod] {
        OracleControl(host: self).methods
    }
}

/// The `overlays` facet's reads, from the owners' state, never a view tree: each window's
/// overlay host (dialogs the host presents, toasts, popovers, menus), its focus model's overlays, its panes' find
/// models, the hover card coordinator and the palette controller.
extension AppServices {
    func oracleOverlays() -> OracleOverlaysFacet.Reading {
        let card = hoverCards.machine.shownTarget
        var cardPlaced = false
        var layers = windows.controllers.map { controller in
            let onCard = card != nil && card?.window == controller.window?.windowNumber
            cardPlaced = cardPlaced || onCard
            return OracleOverlaysFacet.WindowLayers(
                window: ControlWindowInfo.publicID(forKey: controller.state.id),
                findBars: controller.content?.panes.values.filter { Self.oracleFindBar(of: $0)?.open == true }.count ?? 0,
                hosted: Self.oracleHosted(controller.window.flatMap(WindowOverlayHost.existingHost(for:))),
                panels: controller.focus.state.overlays.map(Self.oracleKind), hoverCard: onCard)
        }
        let paletteUnplaced = palette.isVisible && !layers.contains { $0.panels.contains(.palette) }
        layers.append(.init(window: nil, hosted: Self.oracleHosted(WindowOverlayHost.existingAppHost),
                            panels: paletteUnplaced ? [.palette] : [], hoverCard: card != nil && !cardPlaced))
        return OracleOverlaysFacet.Reading(windows: layers, palette: Self.oraclePalette(open: palette.isVisible, palette.model),
                                           hoverCard: card.flatMap { oracleHoverTarget($0.id) },
                                           findBar: windows.active?.focusedPane.flatMap(Self.oracleFindBar(of:)) ?? .init())
    }

    /// A pane's find bar: the terminal's `TerminalFindController` or the browser chrome's `BrowserFindModel`.
    static func oracleFindBar(of pane: PaneController) -> OracleOverlaysFacet.FindBar? {
        switch pane.currentContent {
        case .terminal(let entry)?: oracleFindBar(entry.session.find, pane: pane.pane.id)
        case .browser(let entry)?: oracleFindBar(entry.chrome.find, pane: pane.pane.id)
        default: nil
        }
    }

    static func oracleFindBar(_ find: TerminalFindController, pane: String) -> OracleOverlaysFacet.FindBar {
        .init(open: find.isPresented, pane: pane, query: find.query, matches: find.total ?? 0, selected: find.selected)
    }

    static func oracleFindBar(_ find: BrowserFindModel, pane: String) -> OracleOverlaysFacet.FindBar {
        .init(open: find.isPresented, pane: pane, query: find.query, matches: find.matchCount ?? 0, selected: find.activeIndex)
    }

    /// The host's overlays bottom to top, as the schema's kinds, with their presenters' names.
    static func oracleHosted(_ host: WindowOverlayHost?) -> [OracleOverlaysFacet.Hosted] {
        (host?.stackedHandles ?? []).compactMap { handle in
            oracleHostedKind(handle.options, name: handle.name).map { OracleOverlaysFacet.Hosted($0, name: handle.name) }
        }
    }

    /// Nil for an overlay the person never meets as a layer: one that passes clicks through (a tooltip, a drag
    /// ghost, a swipe arrow, the which-key hint, a toast fading out).
    static func oracleHostedKind(_ options: OverlayOptions, name: String?) -> OracleOverlaysFacet.Kind? {
        guard !options.passesThroughClicks else { return nil }
        switch options.kind {
        case .tooltip, .dragGhost: return nil
        // `.attached` is a control's part drawn on the host: the omnibar's suggestion card.
        case .popover, .attached: return .popover
        case .menu: return .menu
        case .dialog: return .dialog
        case .toast: return name == RefusalHUD.toastID ? .refusalHud : .toast
        }
    }

    static func oracleKind(_ overlay: FocusState.Overlay) -> OracleOverlaysFacet.Kind {
        switch overlay {
        case .palette: .palette
        case .sheet: .sheet
        // The group editor bubble and the rename prompt are panels on a control of the window.
        case .groupEditor, .rename: .popover
        }
    }

    static func oraclePalette(open: Bool, _ model: PaletteModel) -> OracleOverlaysFacet.Palette {
        guard open else { return .init() }
        let rows = model.rows
        return .init(open: true, mode: model.currentPageID, query: model.query, rowIDs: rows.prefix(OracleOverlaysFacet.topCount).map(\.id),
                     selectedIndex: model.selectedRowID.flatMap { selected in rows.firstIndex { $0.id == selected } })
    }

    /// The item of a shown card through its owners' parsers; nil for a card that is no item's (a link chip, whose
    /// target holds its URL) or a workspace with no public id.
    func oracleHoverTarget(_ id: HoverTargetID) -> OracleOverlaysFacet.HoverTarget? {
        if let row = CmuxNextSidebar.WorkspaceID(hoverCardTarget: id) ?? CmuxNextSidebar.WorkspaceID(railHoverTarget: id) {
            return workspace(id: row.rawValue)?.resourceID.map { OracleOverlaysFacet.HoverTarget.workspace($0.rawValue) }
        }
        if let group = CmuxNextSidebar.GroupID(hoverCardTarget: id) { return .group(group.rawValue) }
        return CmuxNextTabs.TabID(hoverCardTarget: id).map { OracleOverlaysFacet.HoverTarget.tab($0.rawValue) }
    }

    nonisolated static func oracleSHA256(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

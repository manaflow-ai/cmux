#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserTabs
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

/// The app's oracle facet providers (p15-oracle.md section 3A), registered as `debug.oracle.*` in DEV and
/// bench builds only: a Release build compiles neither this conformance nor any provider in the list. The
/// facet tasks add theirs to the list; until then each facet
/// answers not-comparable with its task. The router adds `topology` itself (OracleTopologyFacet).
extension AppServices: OracleHost {
    func makeOracleFacets() -> OracleFacets { makeOracleFacets(lanes: [AgentLaneStore.shared, AgentLaneStore.chief]) }

    /// - Parameter lanes: The acpmux lane mirrors the agents facet reads a session's lane from, the first that has it
    ///   (the app's: this Mac's watch, then the Chief home's).
    func makeOracleFacets(lanes: [AgentLaneStore]) -> OracleFacets {
        OracleFacets([
            // Each window's focused pane and the input observation's responder, from InputObservationBuilder.
            InputObservationBuilder.oracleFocusFacet(self),
            // The input check `debug.desync` runs and the window problems `debug.focus` reports, now.
            OracleInvariantsFacet { [weak self] in
                guard let self, let monitor = input.monitor, let result = monitor.check() else { return nil }
                return OracleInvariantsFacet.Reading(violations: result.violations.map(\.invariant.rawValue),
                                                     windowInvariants: WindowInvariants.problems(windows), checks: monitor.checks)
            },
            // Every workspace each window shows, the focused one and the ones `sidebar.multiView` puts beside it.
            OracleLayoutFacet { [weak self] () throws(OracleFacetError) -> [OracleLayoutFacet.Shown] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return windows.controllers.flatMap(\.onScreenContents).map { content in
                    OracleLayoutFacet.Shown(workspace: content.workspace.resourceID?.rawValue ?? content.workspace.id, model: content.layoutModel)
                }
            },
            OracleIntentsFacet(store: daemon.store, turns: oracleTurns),
            OracleTabsFacet { [weak self] in self?.oracleTabPanes() ?? [] },
            // The settings the controller applied (no file read) and the motion arm as the gates compute it from
            // the design settings the controller applied them to.
            OracleSettingsFacet { [weak self] in
                guard let settings = self?.settings else { return nil }
                let applied = settings.applied, motion = Motion.basePolicy(of: settings.design)
                return OracleSettingsFacet.Reading(effectiveSha256: applied.effectiveSha256, nonDefaultKeys: applied.nonDefaultKeys(),
                                                   motionEnabled: motion.animationsEnabled, motionSpeed: motion.speed.timeScale,
                                                   reduceMotion: motion.reduceMotion)
            },
            // The overlay hosts, focus overlays, palette, hover card and find bars; their owners signal changes.
            OracleOverlaysFacet(hash: Self.oracleSHA256, changes: { [overlayChanges] in overlayChanges.subscribe() }) { [weak self] in
                self?.oracleOverlays()
            },
            // The windows front to back, key and main, and each window's state and frame as screen fractions.
            windows.oracleWindowsFacet(events: appEvents),
            // The active window's sidebar from its SidebarModel's public values.
            SidebarSnapshot.oracleFacet(self),
            // What Recently Closed lists, from the daemons' mirrored closed history. Each title is hashed after the
            // request's `paths` (the case root and home, as normalize.py gets them) are rewritten.
            OracleHistoryFacet { [weak self] () throws(OracleFacetError) -> [ClosedItem] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                let closed = DaemonClosedHistory.entries(DaemonClosedHistory.allKinds, in: self)
                return TabSearchFactsBuilder.listed(closed) { ($0.item, $0.daemon.machineID) }.map(\.item)
            },
            // The Dock badge and each workspace's unread count, from this Mac's daemon store, and its Needs you:
            // the agent chats in it whose acpmux lane waits on the person, as the sidebar row and Priority view read it.
            OracleNotificationsFacet { [weak self] () throws(OracleFacetError) -> OracleNotificationsFacet.Reading? in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return try OracleNotificationsFacet.Reading(store: daemon.store, homeUnread: home.unreadConversations.map(\.rawValue)) {
                    AgentLaneStore.shared.needsYou(in: $0, turns: .shared)
                }
            },
            // Agent chat tabs with acpmux's lane for their session, and each Home Messages view's conversation.
            OracleAgentsFacet { [weak self] in
                self?.oracleAgents { session in lanes.lazy.compactMap { $0.lane(session) }.first }
            },
            // The local daemon mirror's terminals in the snapshot's main-actor turn; their screens off the main actor.
            OracleTerminalsFacet(rewrite: .init(rootVariable: environment.oracleRoot, home: environment.launchHome), hash: Self.oracleSHA256,
                                 changes: { [terminalScreenChanges] in terminalScreenChanges.subscribe() }) {
                [weak self] () throws(OracleFacetError) -> [OracleTerminalsFacet.Terminal] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return try oracleTerminals()
            },
            // Each reachable page's own store summary (`cmux.page.oracle.state`), with the tab and pane that show it;
            // the pages signal their changes.
            OracleWebviewsFacet(changes: { [feed = webUI.oracleChanges] in feed.subscribe() }) {
                [weak self] () async throws(OracleFacetError) -> OracleWebviewsFacet.Reading in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return try await oracleWebviews()
            },
            // Child exits by kind: the run this launch follows, Chromium's crash log, and the daemon's loss log.
            OracleCrashesFacet(app: { [weak self] in
                guard let self else { return nil }
                let log = cache.chromium.built?.crashLog, previous = crashRecovery.recovery.previous
                return OracleCrashesFacet.AppExits(previous: previous.map { .init(signal: $0.signal, raisedException: $0.exception != nil) },
                                                   tallies: log?.tallies ?? [:], records: log?.records ?? [])
            }, daemon: { [weak self] () async throws(OracleFacetError) -> [String: Int]? in
                try await OracleCrashesFacet.daemonChildExits(self?.daemon.connection)
            }),
            // Live objects from their owners' tables; Chromium's only once it was built (the read never starts it).
            OracleLiveObjectsFacet { [weak self] in
                guard let self, daemon.store.isLoaded else { return nil }
                return OracleLiveObjectsFacet.Reading(
                    stores: machines.daemons.map(\.store), cefBrowsers: cache.chromium.built?.liveBrowserCount ?? 0,
                    pageViews: cache.browsers.count, terminals: cache.terminals.count,
                    subscriptions: mainWork.observations.snapshot().reduce(0) { $0 + $1.armed }, tasks: mainWork.wakeUps.count)
            },
            // Each window's focusable and actionable AX elements, named by localization key.
            WindowHintTargets.oracleAccessibilityFacet(windows: windows, work: work),
        ])
    }

    /// Every `debug.oracle.*` method over the app's one facet list, the router's topology (`snapshots`) and the
    /// app's one turn recorder, ``oracleTurns`` (the registry's perform-turn observer); `AppControl` registers them.
    @MainActor
    func oracleControlMethods(snapshots: ControlSnapshotStore) -> [ControlMethod] {
        OracleControl.methods(host: self, snapshots: snapshots, turns: oracleTurns)
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

    /// The `terminals` facet's main-actor read: the local daemon's terminals, as the facet says. A
    /// Cloud, SSH or server machine's terminals are not the case's: a reconnecting remote must not fail the snapshot.
    func oracleTerminals() throws(OracleFacetError) -> [OracleTerminalsFacet.Terminal] {
        let connection = machines.local.connection
        return try OracleTerminalsFacet.terminals(in: machines.local.store.workspaces, attach: { [cache] tab in
            (cache.existingTerminal(tab)?.io).map { view in { @Sendable () -> OracleTerminalsFacet.Attach in view.attachPhase.oracleAttach } }
        }) { surface throws(OracleFacetError) -> @Sendable () async throws -> String in
            guard let connection else { throw OracleFacetError("no connection to the local daemon to read surface \(surface.rawValue)") }
            return { try await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(2)).text }
        }
    }

    nonisolated static func oracleSHA256(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

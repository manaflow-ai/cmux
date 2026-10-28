import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Hot-path audit 3, H7 (2026-10-28): every window record save (each selection or focus change: a tab switch, a
/// focus move) builds the windows' records on the main actor. Their selected tabs (`WindowRecordSaver.selectedTabs`)
/// were cached against each store's applied sequence, so after any daemon batch (terminal output titles, an agent's
/// status, a notification) the next save walked every pane of every workspace the window lists. The tabs a save
/// records change only with the selection, the window's workspaces or the panes they hold (the store's tab list
/// revision): a save after a batch that changed none of them reads no pane. CLAUDE.md "Go past Chrome where cmux is
/// scripted": a change costs the items it changes, never the session.
@MainActor @Suite(.serialized) struct WindowRecordSaveCostTests {
    static let windowID = "record-cost"

    /// `workspaces` workspaces (key w<n>, handle n) of one screen with `panes` panes of 2 terminals each.
    static func tree(workspaces: Int, panes: Int) -> DaemonTree {
        DaemonTree(workspaces: (1...workspaces).map { w in
            let paneSnapshots = (0..<panes).map { p in
                let pane = PaneID(rawValue: UInt64(w * 100 + p))
                return PaneSnapshot(id: pane, tabs: (0..<2).map { t in
                    TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 1_000 + p * 10 + t)), title: "zsh")
                })
            }
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(w)), layout: .stack(panes: paneSnapshots.map(\.id), expanded: paneSnapshots[0].id),
                                        panes: paneSnapshots)
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(w)), key: WorkspaceKey(rawValue: "w\(w)"), name: "w\(w)", screens: [screen])
        })
    }

    /// One window listing every workspace, with a tab selected in each workspace's first pane.
    static func rig(workspaces: Int, panes: Int) -> (AppServices, WindowState) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        store.apply(snapshot: tree(workspaces: workspaces, panes: panes))
        let state = WindowState(id: windowID)
        services.windows.states[windowID] = state
        let ids = store.workspaces.map(\.id)
        services.windows.registry.apply { registry in
            registry = WindowRegistry(windows: [.init(id: windowID, workspaceIDs: ids)])
            return WindowRegistry.Changes()
        }
        for workspace in store.workspaces {
            guard let pane = workspace.screens.first?.panes.first, let tab = pane.tabs.last else { continue }
            state.selection.select(tab.id, in: pane.id)
        }
        return (services, state)
    }

    /// A batch as terminal output brings it: one tab's title, at the next sequence.
    static func titleBatch(_ store: DaemonStore, surface: UInt64, title: String) {
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: store.appliedSequence + 1, event: .titleChanged(surface: SurfaceID(rawValue: surface), title: title))])
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    /// The median of `runs` timings of `save`, each after `before` (untimed).
    static func median(_ runs: Int, before: () -> Void, _ save: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            before()
            let start = ContinuousClock.now
            save()
            samples.append(microseconds(ContinuousClock.now - start))
        }
        return samples.sorted()[runs / 2]
    }

    @Test func aSaveAfterATitleBatchCostsWhatASaveWithNoBatchCosts() throws {
        let (services, _) = Self.rig(workspaces: 400, panes: 8)
        let saver = services.windows.recordSaver
        let store = services.machines.local.store
        let records = saver.currentRecords()
        let record = try #require(records.first)
        #expect(record.selectedTabs.count == 400, "each workspace's first pane records its selected tab")
        var title = 0
        let quiet = Self.median(15, before: {}) { _ = saver.currentRecords() }
        let afterBatch = Self.median(15, before: {
            title += 1
            Self.titleBatch(store, surface: 1_000 + 1, title: "build \(title)")
        }) { _ = saver.currentRecords() }
        print("BENCH H7 record-save panes=3200 quiet_us=\(String(format: "%.1f", quiet)) after_title_batch_us=\(String(format: "%.1f", afterBatch))")
        #expect(afterBatch <= max(quiet * 3, quiet + 200),
                "a save after a batch that changed no pane walked the window's 3200 panes: \(afterBatch) us against \(quiet) us")
        #expect(saver.currentRecords().first?.selectedTabs == record.selectedTabs)
    }

    @Test func aPaneThatClosesLeavesTheNextSave() throws {
        let (services, state) = Self.rig(workspaces: 10, panes: 2)
        let saver = services.windows.recordSaver
        let store = services.machines.local.store
        let before = try #require(saver.currentRecords().first)
        let pane = try #require(store.workspaces[3].screens.first?.panes.first)
        #expect(before.selectedTabs[pane.id] != nil)
        // A tab selected in a second pane of workspace 4 (a selection change), then that workspace's first pane closes.
        let second = try #require(store.workspaces[3].screens.first?.panes.last)
        state.selection.select(try #require(second.tabs.first).id, in: second.id)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: store.appliedSequence + 1,
                                                    event: .paneClosed(PaneDelta(workspace: 4, screen: 4, pane: pane.handle, index: nil,
                                                                                 entity: PaneSnapshot(id: pane.handle))))])
        let after = try #require(saver.currentRecords().first)
        #expect(after.selectedTabs[pane.id] == nil, "a closed pane's selection left the record")
        #expect(after.selectedTabs[second.id] == second.tabs.first?.id)
    }

    /// The save's cost after a title batch against the window's size: BENCH lines at 10, 100 and 1000 workspaces of
    /// 4 panes.
    @Test func benchASaveAfterATitleBatchAtTenAHundredAndAThousandWorkspaces() {
        for workspaces in [10, 100, 1_000] {
            let (services, _) = Self.rig(workspaces: workspaces, panes: 4)
            let saver = services.windows.recordSaver
            let store = services.machines.local.store
            var title = 0
            let afterBatch = Self.median(21, before: {
                title += 1
                Self.titleBatch(store, surface: 1_000 + 1, title: "build \(title)")
            }) { _ = saver.currentRecords() }
            print("BENCH H7 record-save-after-batch workspaces=\(workspaces) panes=\(workspaces * 4) median_us=\(String(format: "%.1f", afterBatch))")
        }
    }
}

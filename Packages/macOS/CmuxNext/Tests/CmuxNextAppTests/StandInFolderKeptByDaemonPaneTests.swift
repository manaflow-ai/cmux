import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import os
import Testing

/// The daemon's pane keeps the folder the stand-in tab shows (RESIZE VIDEOS T1, 4 of 4 films on feat e34fecc1312:
/// the new tab's title went "/tmp" -> "Terminal" -> "/tmp", each change a rename crossfade, so two titles were drawn
/// over each other). The stand-in shows the create's folder (#31810); the daemon's first record of the new pane had
/// no folder (its decorations were read before the pane held the surface), so the same tab model lost its folder,
/// and its title fell back to the placeholder until the next tab-changed. The folder must not change at all from
/// the key's frame through the create's settle: one title from the first frame.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StandInFolderKeptByDaemonPaneTests {
    @Test func aSplitNewColumnAndNewRowKeepTheStandInFolderThroughTheDaemonPane() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            let daemon = services.daemon
            let pane = try #require(daemon.store.panesByHandle.values.first {
                $0.handle.rawValue < ProvisionalPane.firstHandle && !$0.tabs.isEmpty
            }, "the app has a daemon pane")
            let folder = "/private/tmp"
            let options = SpawnOptions(cwd: folder)
            let split = ProvisionalPane(), column = ProvisionalPane(columnWidth: 0.4), row = ProvisionalPane(rowHeight: 300)
            let creates: [(String, ProvisionalPane, @MainActor () -> @MainActor () async throws -> SurfaceCreated)] = [
                ("split", split, { PaneSplitCommand(pane: pane.handle, direction: .right, options: options, swapTowards: nil)
                    .intendNow(on: daemon, provisional: split) }),
                ("new column", column, { NewColumnCommand(pane: pane.handle, width: 0.4, options: options)
                    .intendNow(on: daemon, provisional: column) }),
                ("new row", row, { NewRowCommand(pane: pane.handle, height: 300, options: options)
                    .intendNow(on: daemon, provisional: row) }),
            ]
            for (name, provisional, intend) in creates {
                let send = intend()
                let standIn = try #require(daemon.store.panesByHandle[provisional.handle], "\(name): the stand-in shows in the key's turn")
                let tab = try #require(standIn.tabs.first)
                #expect(tab.cwd == folder, "\(name): the stand-in tab has no folder (\(tab.cwd ?? "nil"))")
                // Any write of a different folder to this tab model (the daemon's pane takes the stand-in's models
                // over in place) is a change of its title.
                let changed = OSAllocatedUnfairLock(initialState: false)
                withObservationTracking { _ = tab.cwd } onChange: { changed.withLock { $0 = true } }
                // Returns once the store holds the daemon's pane (its pane-added applied).
                _ = try await send()
                #expect(tab.resourceID?.rawValue == provisional.tabID, "\(name): the daemon's tab took the stand-in's model over")
                #expect(!changed.withLock { $0 }, "\(name): the daemon's pane changed the stand-in's folder (now \(tab.cwd ?? "nil")), so its title changed")
                #expect(tab.cwd == folder, "\(name): the daemon's tab shows \(tab.cwd ?? "nil"), not the create's folder")
            }
        }
    }
}

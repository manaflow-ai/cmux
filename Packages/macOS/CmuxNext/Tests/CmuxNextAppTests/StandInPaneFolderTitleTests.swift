import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// A split's, New Column's and New Row's stand-in terminal shows the folder it opens in from the key's frame (RESIZE
/// VIDEOS T1, 5 of 5 films: the new pane's tab drew '/private/tmp' over 'Terminal' for about 80 ms). The stand-in tab
/// was made with no folder, so its title was the placeholder "Terminal"; the daemon's tab, under the same tab id,
/// came with its folder, and the strip crossfaded the "rename" on one title layer: two titles at once. The create's
/// folder (the one it sends) is the stand-in's now, so the title does not change when the daemon's tab arrives.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StandInPaneFolderTitleTests {
    @Test func aSplitNewColumnAndNewRowStandInShowItsFolderInTheKeysTurn() async throws {
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
                #expect(TabItemMapping.shared.title(tab, fallbackTitle: "Terminal") != "Terminal",
                        "\(name): the stand-in's title is the placeholder, so the daemon's tab renames it")
                _ = try? await send()
            }
        }
    }
}

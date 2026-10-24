import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFiles
import Darwin
import Foundation
import Testing

/// Paste Last Screenshot at its action entrypoint (review 2 of pl-instant-swift): the run is a
/// counted `.waiting(.fileSystem)` and the screenshot folder is listed off the main actor. The
/// folder reader's own tests (NewestPictureTests) cannot see the handler: a handler that went back
/// to a synchronous listing on main kept them green. Here the listing reports the thread it ran on.
@MainActor @Suite(.serialized)
struct PasteLastScreenshotOffMainTests {
    @Test func theFolderIsListedOffTheMainActorAndTheRunWaitsOnTheFileSystem() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let listings = ScreenshotListings()
        services.screenshotLister = MainThreadRecordingLister(listings: listings)
        AppActions.bind(services)
        let terminal = TabSnapshot(surface: 1, kind: .pty, title: "zsh", url: "")
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "shell", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [terminal])]),
            ]),
        ]))
        let tab = try #require(services.machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)

        // No window shows the terminal here, so the run says its key context (a focused terminal) itself.
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)
        invocation.keyContext = [.terminalFocused]
        let work = services.registry.capturingWork {
            #expect(services.registry.perform("pasteLastScreenshot", invocation: invocation), "the action did not run")
        }
        #expect(services.registry.waitingRuns["pasteLastScreenshot"]?[.fileSystem] == 1,
                "waiting runs: \(services.registry.waitingRuns)")
        #expect(work.count == 1, "the folder read is the run's tracked remote half")
        var failures: [ActionWorkFailure?] = []
        for task in work { failures.append(await task.value) }
        #expect(failures.count == 1)
        #expect(failures.first??.refusal == .unavailable, "an empty folder has no screenshot to paste: \(failures)")
        #expect(await listings.onMain == [false], "the screenshot folder was listed on the main thread")
    }
}

/// Where each screenshot folder listing ran (true: the main thread).
private actor ScreenshotListings {
    private(set) var onMain: [Bool] = []

    func note(onMain main: Bool) { onMain.append(main) }
}

/// A folder lister that records whether it was called on the main thread and lists an empty folder.
/// Its `list` is not `@concurrent`, so it runs where its caller runs.
private nonisolated struct MainThreadRecordingLister: DirectoryListing {
    let listings: ScreenshotListings

    func list(_ folder: URL) async throws -> [FileEntry] {
        let main = pthread_main_np() != 0
        await listings.note(onMain: main)
        return []
    }

    func entry(at url: URL) async -> FileEntry? { nil }
}

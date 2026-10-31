import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// #26681: after a nightly relaunch one of two open windows did not come back. The daemon, still
/// starting, answered the launch's read of the saved window records after the 2 s control-plane
/// deadline; the failure read as "nothing saved", the launch window took every workspace, and its
/// first save replaced the stored records (two open windows, eighteen closed) with that one window.
/// Saves stay blocked until the saved registry is installed, including while reads time out or
/// reconnect (`SavedWindowsRead`, its retry tests are in CmuxNextDaemonTests).
@MainActor @Suite(.serialized)
struct SavedWindowsLaunchTests {
    /// Before the launch read the records (a quit while the daemon still starts), nothing may save:
    /// the quit flush would write this launch's windows, none yet, over the saved ones.
    @Test func recordsCountAsUnreadUntilTheLaunchReadsThem() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.windows.savedWindowsUnread)
        #expect(!services.windows.restored)
    }

    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aHydratedLaunchCanSaveItsWindows() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let windows = services.windows
            #expect(windows.restored)
            #expect(!windows.savedWindowsUnread)
            let windowState = try #require(services.daemon.windowState)
            _ = await windows.recordSaver.saveNow()
            let saved = try await windowState.load()
            #expect(!saved.windows.isEmpty)
            #expect(Set(saved.windows.map(\.id)) == Set(windows.recordSaver.currentRecords().map(\.id)))
        }
    }

    /// Against a same-tree cmux-tui: while the launch's read waits and after it failed, a save leaves
    /// the stored records as they were (both windows), where before its first save kept only its own
    /// window. A read that answers lets saves through again.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aLaunchThatCouldNotReadTheSavedWindowsNeverReplacesThem() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let windows = services.windows
            let windowState = try #require(services.daemon.windowState)
            let live = try #require(services.daemon.store.workspaces.compactMap(\.key).first)
            // Settle the launch's own saves first: one in flight could land after the seed below.
            await windows.recordSaver.flushSaves()
            let saved = ["saved-front", "saved-second"]
            try await windowState.update { document in
                document.windows = saved.map { WindowRecord(id: $0, workspaceKey: live, workspaceKeys: [live]) }
            }
            // A slow daemon: every attempt times out; a save asked for meanwhile writes nothing.
            var savedDuringRead: [String] = []
            let document = await windows.readSavedWindows(SavedWindowsRead(attempts: 2, attemptTimeout: .milliseconds(10))) { _ in
                _ = await windows.recordSaver.saveNow()
                savedDuringRead = try await windowState.load().windows.map(\.id)
                throw DaemonError.timedOut("frontend_projection.get")
            }
            #expect(savedDuringRead == saved, "a save during the read replaced the saved windows")
            #expect(document == nil)
            #expect(windows.savedWindowsUnread)
            _ = await windows.recordSaver.saveNow()
            #expect(try await windowState.load().windows.map(\.id) == saved,
                    "the unread launch replaced the saved windows with its own")

            // A read that answers still cannot save before its records have been installed.
            let read = await windows.readSavedWindows()
            #expect(read?.windows.map(\.id) == saved)
            #expect(windows.savedWindowsUnread)
            _ = await windows.recordSaver.saveNow()
            #expect(try await windowState.load().windows.map(\.id) == saved)
        }
    }
}

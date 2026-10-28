import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// #26681: after a nightly relaunch one of two open windows did not come back. The daemon, still
/// starting, answered the launch's read of the saved window records after the 2 s control-plane
/// deadline; the failure read as "nothing saved", the launch window took every workspace, and its
/// first save replaced the stored records (two open windows, eighteen closed) with that one window.
/// When the read fails, the launch never writes the records, so the next launch restores every
/// window (`SavedWindowsRead`, its retry tests are in CmuxNextDaemonTests).
@MainActor @Suite(.serialized)
struct SavedWindowsLaunchTests {
    /// Against a same-tree cmux-tui: a launch that could not read the stored records leaves them as
    /// they were (both windows), where before its first save kept only its own window.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aLaunchThatCouldNotReadTheSavedWindowsNeverReplacesThem() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let windowState = try #require(services.daemon.windowState)
            let live = try #require(services.daemon.store.workspaces.compactMap(\.key).first)
            services.windows.savedWindowsUnread = true
            try await windowState.update { document in
                document.windows = [
                    WindowRecord(id: "saved-front", workspaceKey: live, workspaceKeys: [live]),
                    WindowRecord(id: "saved-second", workspaceKey: live, workspaceKeys: [live]),
                ]
            }
            _ = await services.windows.recordSaver.saveNow()
            #expect(try await windowState.load().windows.map(\.id) == ["saved-front", "saved-second"],
                    "the unread launch replaced the saved windows with its own")

            // Control: a launch that read its records writes its own windows.
            services.windows.savedWindowsUnread = false
            _ = await services.windows.recordSaver.saveNow()
            #expect(try await windowState.load().windows.map(\.id) != ["saved-front", "saved-second"])
        }
    }
}

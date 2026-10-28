import Darwin
import Foundation
import Testing
@testable import CmuxHomeCore

/// A Home draft survives a forced end of the app (audit 4, P15): a crash, a SIGKILL, a power loss or
/// an Activity Monitor force quit runs no quit step, so the coalesced cache batch (250 ms in the app)
/// never reaches disk. The draft is saved as it is typed, through a write-ahead record beside the
/// cache, and the next launch's cache read puts it back. A real SIGKILL ends a child process (a
/// Swift Testing exit test) right after the keystroke; the parent reads the cache as a relaunch does.
@Suite struct HomeDraftKillTests {
    static let austin = ConversationID("conv_austin")

    /// The child's cache folder: named by the parent test process, so parallel runs never share one.
    static func folder(parent: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-kill-\(parent)", isDirectory: true)
    }

    @Test func aDraftTypedJustBeforeASIGKILLIsThereAtTheNextLaunch() async throws {
        let folder = Self.folder(parent: getpid())
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(processExitsWith: .signal(SIGKILL)) {
            await HomeDraftKillTests.typeThenDie(in: HomeDraftKillTests.folder(parent: getppid()))
        }
        let relaunch = HomeCache(url: folder.appendingPathComponent("home.json"))
        #expect(relaunch.load()?.drafts[Self.austin] == "half a thought")
    }

    /// The child: one keystroke's draft, then a SIGKILL a moment later (no quit step, no flush, no deinit).
    @MainActor static func typeThenDie(in folder: URL) async {
        let cache = HomeCache(url: folder.appendingPathComponent("home.json"))
        // The app's batch would write in 250 ms; this one never does before the kill.
        let view = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        view.setDraft("half a thought", for: austin)
        try? await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(view) { _ = kill(getpid(), SIGKILL) }
    }
}

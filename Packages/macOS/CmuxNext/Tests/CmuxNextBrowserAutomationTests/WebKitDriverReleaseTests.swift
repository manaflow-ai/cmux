import CmuxNextBrowser // a dependency of CmuxNextBrowserAutomation (its public API names WebKitTab)
@testable import CmuxNextBrowserAutomation
import Foundation
import Testing

/// The driver's nonisolated deinit ends its event stream on the thread that releases it, main or not,
/// so the host's event loop over `events` returns. It used to return early off the main thread
/// (`guard Thread.isMainThread else { return }`), which left that loop waiting for good.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WebKitDriverReleaseTests {
    // crash-allow: the other thread writes `driver` and `releasedThere` once while the test awaits that thread's resume, so no two threads touch them at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var driver: WebKitDriver?
        /// Whether the driver was deallocated on the releasing thread (its deinit ran there).
        var releasedThere = false
    }

    /// An App with no tabs.
    final class NoTabs: AutomationTabProvider {
        struct NoTab: Error {}
        func automationTabs(all: Bool) -> [AutomationTab] { [] }
        func openAutomationTab(url: URL?) async throws -> WebKitTab { throw NoTab() }
        func closeAutomationTab(_ id: BrowserTabID) {}
        func endSessionTab(_ id: String) async -> Bool { false }
        func activateAutomationTab(_ id: BrowserTabID) {}
    }

    @Test(arguments: [false, true])
    func releasingTheDriverEndsItsEventStream(offMain: Bool) async throws {
        let provider = NoTabs()
        let handoff = Handoff()
        handoff.driver = WebKitDriver(provider: provider)
        let events = try #require(handoff.driver?.events)
        if offMain {
            await Self.releaseOnAnotherThread(handoff)
            #expect(handoff.releasedThere, "the driver outlived its release on the other thread, so its deinit did not run there")
        } else {
            handoff.driver = nil
        }
        var received = 0
        for await _ in events { received += 1 }
        #expect(received == 0)
    }

    /// Drops the handoff's driver, its last reference, on a new thread, records in `releasedThere`
    /// whether it was deallocated there, and resumes once that thread is done. The driver runs no
    /// task that could hold it, so the test can await instead of blocking the main actor.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) async {
        await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                weak var probe = handoff.driver
                handoff.driver = nil
                handoff.releasedThere = probe == nil
                released.resume()
            }
        }
    }
}

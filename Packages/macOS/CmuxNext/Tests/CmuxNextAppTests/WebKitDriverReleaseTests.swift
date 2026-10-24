import CmuxNextBrowser
@testable import CmuxNextBrowserAutomation
import Foundation
import Testing

/// The driver's nonisolated deinit ends its event stream on the thread that releases it, main or not,
/// so the host's event loop over `events` returns. It used to return early off the main thread
/// (`guard Thread.isMainThread else { return }`), which left that loop waiting for good.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WebKitDriverReleaseTests {
    // crash-allow: the other thread writes `driver` once while the main thread waits on the semaphore, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var driver: WebKitDriver?
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
            Self.releaseOnAnotherThread(handoff)
        } else {
            handoff.driver = nil
        }
        var received = 0
        for await _ in events { received += 1 }
        #expect(received == 0)
    }

    /// Drops the handoff's driver, its last reference, on a new thread and returns once it is gone.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.driver = nil
            released.signal()
        }
        released.wait()
    }
}

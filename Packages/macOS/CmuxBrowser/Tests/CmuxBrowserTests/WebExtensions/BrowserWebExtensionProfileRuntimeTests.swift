import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser WebExtension profile runtime")
@MainActor
struct BrowserWebExtensionProfileRuntimeTests {
    @Test func readyLoadReleasesQueuedNavigationExactlyOnce() async throws {
        let loadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let deadlineGate = BrowserWebExtensionTestGate<Void>()
        let profileID = UUID()
        let intent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#ready"),
            reason: .initial
        )
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { await deadlineGate.wait() }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()

        runtime.enqueueNavigation(intent)
        runtime.start { await loadGate.wait() }
        await loadGate.resume(with: .ready)

        var releases: [BrowserWebExtensionNavigationIntent] = []
        while releases.isEmpty {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before navigation release")
                return
            }
            if case .navigationReleased(let released, .ready) = update {
                releases.append(released)
            }
        }
        await Task.yield()
        #expect(releases == [intent])
        #expect(runtime.phase == .ready)
        #expect(runtime.pendingNavigationCount == 0)
    }

    @Test func deadlineDegradesAndReleasesQueuedNavigationExactlyOnce() async throws {
        let loadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let deadlineGate = BrowserWebExtensionTestGate<Void>()
        let profileID = UUID()
        let intent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#deadline"),
            reason: .restore
        )
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { await deadlineGate.wait() }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()

        runtime.enqueueNavigation(intent)
        runtime.start { await loadGate.wait() }
        await deadlineGate.resume(with: ())

        var releaseCount = 0
        while releaseCount == 0 {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before deadline release")
                return
            }
            if case .navigationReleased(let released, .deadlineExceeded) = update {
                #expect(released == intent)
                releaseCount += 1
            }
        }
        #expect(runtime.phase == .degraded(.loadDeadlineExceeded))
        #expect(releaseCount == 1)
    }

    @Test func lateLoadCompletionDoesNotReplayReleasedNavigation() async throws {
        let loadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let deadlineGate = BrowserWebExtensionTestGate<Void>()
        let profileID = UUID()
        let intent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#late"),
            reason: .recovery
        )
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { await deadlineGate.wait() }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()

        runtime.enqueueNavigation(intent)
        runtime.start { await loadGate.wait() }
        await deadlineGate.resume(with: ())

        var releaseCount = 0
        while releaseCount == 0 {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before deadline release")
                return
            }
            if case .navigationReleased = update { releaseCount += 1 }
        }
        await loadGate.resume(with: .ready)
        await Task.yield()

        #expect(runtime.phase == .ready)
        #expect(runtime.pendingNavigationCount == 0)
        #expect(releaseCount == 1)
    }

    @Test func cancellationRemovesQueuedNavigation() async throws {
        let loadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let deadlineGate = BrowserWebExtensionTestGate<Void>()
        let profileID = UUID()
        let intent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#cancel"),
            reason: .profileSwitch
        )
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { await deadlineGate.wait() }
        )
        runtime.start { await loadGate.wait() }
        runtime.enqueueNavigation(intent)

        #expect(runtime.cancelNavigation(id: intent.id))
        await deadlineGate.resume(with: ())
        await Task.yield()

        #expect(runtime.pendingNavigationCount == 0)
        #expect(runtime.phase == .degraded(.loadDeadlineExceeded))
    }

    @Test func healthyReloadRecoversWithoutReplayingOldIntents() async throws {
        let firstLoadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let firstDeadlineGate = BrowserWebExtensionTestGate<Void>()
        let profileID = UUID()
        let oldIntent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#old"),
            reason: .initial
        )
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { await firstDeadlineGate.wait() }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()
        runtime.enqueueNavigation(oldIntent)
        runtime.start { await firstLoadGate.wait() }
        await firstDeadlineGate.resume(with: ())

        while true {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before deadline release")
                return
            }
            if case .navigationReleased = update { break }
        }

        runtime.start { .ready }
        await Task.yield()

        #expect(runtime.phase == .ready)
        #expect(runtime.pendingNavigationCount == 0)
        let newIntent = BrowserWebExtensionNavigationIntent(
            profileID: profileID,
            targetURL: URL(string: "about:blank#new"),
            reason: .userInitiated
        )
        runtime.enqueueNavigation(newIntent)
        #expect(runtime.pendingNavigationCount == 0)
    }
}

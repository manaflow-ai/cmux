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
        runtime.start { .ready }
        var observedRecoveryReady = false
        while !observedRecoveryReady {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before readiness replay check")
                return
            }
            switch update {
            case .phaseChanged(.ready):
                observedRecoveryReady = true
            case .navigationReleased(let released, _):
                releases.append(released)
            default:
                break
            }
        }
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

        var releasedIntents: [BrowserWebExtensionNavigationIntent] = []
        while releasedIntents.isEmpty {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before deadline release")
                return
            }
            if case .navigationReleased(let released, .deadlineExceeded) = update {
                #expect(released == intent)
                releasedIntents.append(released)
            }
        }
        #expect(runtime.phase == .degraded(.loadDeadlineExceeded))
        #expect(releasedIntents == [intent])
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

        var releasedIntents: [BrowserWebExtensionNavigationIntent] = []
        while releasedIntents.isEmpty {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before deadline release")
                return
            }
            if case .navigationReleased(let released, _) = update {
                releasedIntents.append(released)
            }
        }
        await loadGate.resume(with: .ready)
        var observedLateReady = false
        while !observedLateReady {
            guard let update = await updates.next() else {
                Issue.record("Update stream ended before late readiness")
                return
            }
            switch update {
            case .phaseChanged(.ready):
                observedLateReady = true
            case .navigationReleased(let released, _):
                releasedIntents.append(released)
            default:
                break
            }
        }

        #expect(runtime.phase == .ready)
        #expect(runtime.pendingNavigationCount == 0)
        #expect(releasedIntents == [intent])
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
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()
        runtime.start { await loadGate.wait() }
        runtime.enqueueNavigation(intent)

        #expect(runtime.cancelNavigation(id: intent.id))
        await deadlineGate.resume(with: ())
        while runtime.phase != .degraded(.loadDeadlineExceeded) {
            guard await updates.next() != nil else {
                Issue.record("Update stream ended before degraded phase")
                return
            }
        }

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

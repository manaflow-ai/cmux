import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser WebExtension profile runtime")
@MainActor
struct BrowserWebExtensionProfileRuntimeTests {
    @Test func presentationUpdatesFilterOtherPanelsAndKeepNewestBoundedValues() async throws {
        let profileID = UUID()
        let targetPanelID = UUID()
        let otherPanelID = UUID()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        let stream = runtime.presentationUpdates(for: targetPanelID)

        runtime.publishActionUpdate(BrowserWebExtensionActionUpdate(
            profileID: profileID,
            panelID: otherPanelID,
            item: Self.actionItem(index: -1)
        ))
        for index in 0..<40 {
            runtime.publishActionUpdate(BrowserWebExtensionActionUpdate(
                profileID: profileID,
                panelID: targetPanelID,
                item: Self.actionItem(index: index)
            ))
        }

        var iterator = stream.makeAsyncIterator()
        var observedIndexes: [Int] = []
        while observedIndexes.count < 32 {
            guard let update = await iterator.next() else {
                Issue.record("Presentation stream ended before buffered values")
                return
            }
            guard case .actionChanged(let actionUpdate) = update,
                  let badge = actionUpdate.item?.badgeText,
                  let index = Int(badge) else {
                Issue.record("Presentation stream emitted unrelated panel or lifecycle data")
                return
            }
            observedIndexes.append(index)
        }

        #expect(observedIndexes == Array(8..<40))
    }

    @Test func lifecycleUpdatesRemainLosslessBeyondPresentationBufferCapacity() async throws {
        let profileID = UUID()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        let stream = runtime.updates()
        let intents = (0..<40).map { index in
            BrowserWebExtensionNavigationIntent(
                profileID: profileID,
                targetURL: URL(string: "about:blank#\(index)"),
                reason: .restore
            )
        }
        for intent in intents { runtime.enqueueNavigation(intent) }
        runtime.start { .ready }
        await Task.yield()

        var iterator = stream.makeAsyncIterator()
        var releasedIDs = Set<UUID>()
        while releasedIDs.count < intents.count {
            guard let update = await iterator.next() else {
                Issue.record("Lifecycle stream ended before every navigation release")
                return
            }
            if case .navigationReleased(let intent, .ready) = update {
                releasedIDs.insert(intent.id)
            }
        }
        #expect(releasedIDs == Set(intents.map(\.id)))
    }

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

    @Test func lateLoadCompletionCannotRecoverExpiredGeneration() async throws {
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
        await Task.yield()
        await Task.yield()

        #expect(runtime.phase == .degraded(.loadDeadlineExceeded))
        #expect(!runtime.isLoadAttemptInFlight)
        #expect(runtime.pendingNavigationCount == 0)
        #expect(releasedIntents == [intent])
    }

    @Test func deadlineCancelsNeverReturningGenerationAndAllowsRetry() async throws {
        let firstLoadGate = BrowserWebExtensionTestGate<BrowserWebExtensionLoadOutcome>()
        let deadlineGate = BrowserWebExtensionTestGate<Void>()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: UUID(),
            waitForDeadline: { await deadlineGate.wait() }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()

        runtime.start { await firstLoadGate.wait() }
        #expect(runtime.isLoadAttemptInFlight)
        await deadlineGate.resume(with: ())
        while runtime.phase != .degraded(.loadDeadlineExceeded) {
            _ = await updates.next()
        }

        #expect(runtime.phase == .degraded(.loadDeadlineExceeded))
        #expect(!runtime.isLoadAttemptInFlight)

        runtime.start { .ready }
        while runtime.phase != .ready {
            _ = await updates.next()
        }
        #expect(runtime.phase == .ready)
        #expect(!runtime.isLoadAttemptInFlight)

        await firstLoadGate.resume(with: .degraded(.loadFailed))
        await Task.yield()
        #expect(runtime.phase == .ready)
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

    private static func actionItem(index: Int) -> BrowserWebExtensionPresentationItem {
        BrowserWebExtensionPresentationItem(
            id: "extension",
            name: "Extension",
            hasAction: true,
            isToolbarPinned: true,
            isActionEnabled: true,
            isAwaitingPopup: false,
            badgeText: String(index),
            iconData: nil
        )
    }
}

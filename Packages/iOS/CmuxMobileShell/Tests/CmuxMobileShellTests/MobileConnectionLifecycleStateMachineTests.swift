import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileConnectionLifecycleStateMachineTests {
    @Test func mixedBackgroundTriggersBecomeOneEpisode() {
        let now = Date()
        var reducer = MobileConnectionLifecycleStateMachine()
        reducer.becameInactive(at: now)
        for _ in 0..<200 {
            #expect(reducer.request(.networkPathChanged, health: .healthy) == nil)
            #expect(reducer.request(.presenceRoutesChanged, health: .healthy) == nil)
        }

        let effect = reducer.becameActive(
            at: now.addingTimeInterval(31),
            shortDwellThreshold: 30,
            health: .healthy
        )
        guard case .start(let episode) = effect else {
            Issue.record("one foreground episode must own every deferred trigger")
            return
        }
        #expect(episode.kind == .reconnect)
        #expect(reducer.activeEpisode?.id == episode.id)
        #expect(reducer.request(.networkPathChanged, health: .healthy) == nil)
    }

    @Test func staleCompletionAndResetCannotCommit() {
        var reducer = MobileConnectionLifecycleStateMachine()
        guard case .start(let episode) = reducer.request(.manualRetry, health: .healthy) else {
            Issue.record("manual retry must start one episode")
            return
        }

        #expect(reducer.complete(id: episode.id &+ 1, health: .healthy) == nil)
        #expect(reducer.ownsEpisode(episode.id))
        reducer.reset()
        #expect(!reducer.ownsEpisode(episode.id))
        #expect(reducer.activeEpisode == nil)
    }

    @MainActor
    @Test func staleShellFinishCannotDropNewerEpisodeTaskHandle() {
        let store = MobileShellComposite.preview()
        let health = MobileConnectionLifecycleHealthSnapshot.healthy
        guard case .start(let oldEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: health
        ) else {
            Issue.record("first episode must start")
            return
        }
        store.connectionLifecycle.reset()
        guard case .start(let newEpisode) = store.connectionLifecycle.request(
            .manualRetry,
            health: health
        ) else {
            Issue.record("replacement episode must start")
            return
        }
        store.connectionLifecycleTask = Task {}

        store.finishConnectionLifecycleEpisode(id: oldEpisode.id)

        #expect(store.connectionLifecycle.ownsEpisode(newEpisode.id))
        #expect(store.connectionLifecycleTask != nil)
    }
}

private extension MobileConnectionLifecycleHealthSnapshot {
    static var healthy: Self {
        Self(
            connected: true,
            hasClient: true,
            hasListener: true,
            eventStreamFresh: true,
            canReconnectPersistedMac: true
        )
    }
}

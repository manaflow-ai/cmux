import Foundation
import CmuxMobileTransport
import Testing
@testable import CmuxMobileChief

@MainActor
@Suite(.timeLimit(.minutes(2))) struct HomeRetryTests {
    @Test func failedHomeLoadRetriesTheFeedOnTheExistingLink() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { owner.respond($0) }
        link.failNextOpen = true
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-home")
        #expect(feed.problem != nil)
        #expect(feed.rows == nil)
        var reconnected: [String] = []

        await HomeRetryAction(feed: feed, reconnect: { reconnected.append($0) })
            .retry(macID: "mac-home", reconnectNeeded: false)

        #expect(await MacHomeFeedTests().until { feed.rows?.count == 4 })
        #expect(owner.inboxReads > 0)
        #expect(feed.problem == nil)
        #expect(reconnected.isEmpty)
    }

    /// The Retry's spinner turns for as long as its action runs: the action must end
    /// when the read has answered, not the moment it is requested (it ended at once,
    /// so the spinner flashed for a frame and the capsule jumped on every tap).
    @Test func homeRetryReturnsOnlyAfterTheReadAnswers() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { owner.respond($0) }
        link.failNextOpen = true
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-home")
        #expect(feed.problem != nil)

        await HomeRetryAction(feed: feed).retry(macID: "mac-home", reconnectNeeded: false)

        // No polling: the rows are already in when the retry returns.
        #expect(feed.rows?.count == 4)
        #expect(feed.problem == nil)
    }

    @Test func homeRetryOnALiveChannelWaitsForItsRead() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { owner.respond($0) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-home")
        #expect(await MacHomeFeedTests().until { feed.rows != nil })
        let before = owner.inboxReads

        await HomeRetryAction(feed: feed).retry(macID: "mac-home", reconnectNeeded: false)

        #expect(owner.inboxReads > before)
        #expect(feed.problem == nil)
    }

    /// A channel that goes quiet without closing never answers the read: the retry
    /// comes back after its cap, so Retry can be tapped again (it does not spin forever).
    @Test func homeRetryComesBackWhenTheReadNeverAnswers() async {
        let owner = FakeHomeOwner()
        let quiet = QuietSwitch()
        let link = PushLink { request in
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            if quiet.isOn, object?["cmd"] as? String == "home-inbox" { return [] }
            return owner.respond(request)
        }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-home")
        #expect(await MacHomeFeedTests().until { feed.rows != nil })
        quiet.isOn = true
        let clock = ContinuousClock()
        let start = clock.now

        await feed.reload(cap: .milliseconds(200))

        #expect(clock.now - start >= .milliseconds(200))
        #expect(clock.now - start < .seconds(10))
    }

    @Test func offlineHomeRetryRequestsOnlyItsOwningMac() async {
        let feed = MacHomeFeed()
        var reconnected: [String] = []
        let action = HomeRetryAction(feed: feed, reconnect: { reconnected.append($0) })
        await action.retry(macID: "mac-home", reconnectNeeded: true)
        await action.retry(macID: nil, reconnectNeeded: true)
        #expect(reconnected == ["mac-home"])
        // No fake success while the link is still absent.
        #expect(feed.rows == nil)
    }

    @Test func delayedHomeReconnectCompletesBeforeRefresh() async {
        let feed = MacHomeFeed()
        var order: [String] = []
        let action = HomeRetryAction(feed: feed, reconnect: { _ in
            order.append("reconnect-start")
            try? await Task.sleep(for: .milliseconds(20))
            order.append("reconnect-done")
        }, refresh: {
            order.append("refresh")
        })

        await action.retry(macID: "mac-home", reconnectNeeded: true)

        #expect(order == ["reconnect-start", "reconnect-done", "refresh"])
    }

    @Test func delayedConversationReconnectCompletesBeforeRefresh() async {
        let loader = MacConversationLoader()
        var order: [String] = []

        await loader.retry(macID: "mac-home", reconnect: { _ in
            order.append("reconnect-start")
            try? await Task.sleep(for: .milliseconds(20))
            order.append("reconnect-done")
        }, refresh: {
            order.append("refresh")
        })

        #expect(order == ["reconnect-start", "reconnect-done", "refresh"])
        #expect(loader.retryID == 1)
    }

    @Test func cancelledHomeReconnectDoesNotRefresh() async {
        let feed = MacHomeFeed()
        var refreshes = 0
        let (started, signal) = AsyncStream<Void>.makeStream()
        let action = HomeRetryAction(feed: feed, reconnect: { _ in
            signal.yield()
            try? await Task.sleep(for: .seconds(10))
        }, refresh: { refreshes += 1 })
        let task = Task { @MainActor in
            await action.retry(macID: "mac-home", reconnectNeeded: true)
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await task.value
        #expect(refreshes == 0)
    }

    @Test func cancelledConversationReconnectDoesNotRefreshOrAdvanceRetry() async {
        let loader = MacConversationLoader()
        var refreshes = 0
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            await loader.retry(macID: "mac-home", reconnect: { _ in
                signal.yield()
                try? await Task.sleep(for: .seconds(10))
            }, refresh: { refreshes += 1 })
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await task.value
        #expect(refreshes == 0)
        #expect(loader.retryID == 0)
    }

    @Test func conversationRetryInvokesSessionLoaderAgainAfterFailure() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { owner.respond($0) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-conversation")
        #expect(await MacHomeFeedTests().until { feed.rows != nil })
        let route = MacConversationRoute(conversationID: "conv_ops", chief: nil, title: "Ops")
        let loader = MacConversationLoader()
        var calls = 0
        let load: @MainActor () async throws -> ChiefSession = {
            calls += 1
            return try await feed.session(for: route)
        }
        link.failNextOpen = true
        await loader.load(load)
        #expect(loader.failed)
        #expect(loader.session == nil)
        #expect(calls == 1)
        var reconnected: [String] = []

        await loader.retry(macID: "mac-conversation", reconnect: { reconnected.append($0) })
        #expect(loader.retryID == 1)
        #expect(reconnected == ["mac-conversation"])
        await loader.load(load)

        #expect(calls == 2)
        #expect(!loader.failed)
        #expect(loader.session?.macID == "mac-conversation")
        #expect(loader.session?.identity.chiefID == "agent_codex")
        #expect(try await feed.session(for: route) === loader.session)
    }

    @Test func cancelledLoadDoesNotPublishFailure() async {
        let loader = MacConversationLoader()
        let task = Task { @MainActor in
            await loader.load {
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        }
        await task.value
        #expect(!loader.failed)
        #expect(loader.session == nil)
    }
}

/// Makes a fake Mac stop answering home-inbox reads.
final class QuietSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

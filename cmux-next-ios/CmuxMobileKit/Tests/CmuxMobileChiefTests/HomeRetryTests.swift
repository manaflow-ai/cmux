import CmuxMobileTransport
import Testing
@testable import CmuxMobileChief

@MainActor
@Suite struct HomeRetryTests {
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

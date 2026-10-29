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

        HomeRetryAction(feed: feed, reconnect: { reconnected.append($0) })
            .retry(macID: "mac-home", reconnectNeeded: false)

        #expect(await MacHomeFeedTests().until { feed.rows?.count == 4 })
        #expect(owner.inboxReads > 0)
        #expect(feed.problem == nil)
        #expect(reconnected.isEmpty)
    }

    @Test func offlineHomeRetryRequestsOnlyItsOwningMac() {
        let feed = MacHomeFeed()
        var reconnected: [String] = []
        let action = HomeRetryAction(feed: feed, reconnect: { reconnected.append($0) })
        action.retry(macID: "mac-home", reconnectNeeded: true)
        action.retry(macID: nil, reconnectNeeded: true)
        #expect(reconnected == ["mac-home"])
        // No fake success while the link is still absent.
        #expect(feed.rows == nil)
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

        loader.retry(macID: "mac-conversation", reconnect: { reconnected.append($0) })
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

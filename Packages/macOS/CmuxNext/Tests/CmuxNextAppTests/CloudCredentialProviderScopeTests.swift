import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor @Suite
struct CloudCredentialProviderScopeTests {
    private func register(_ provider: CloudCredentialProvider, _ world: CloudCredentialProviderWorld) async -> Bool {
        await provider.register(userOriginAllowed: true, send: { await world.register($0) }, invalidate: { try await world.invalidate($0) })
    }
    private func call(_ provider: CloudCredentialProvider, id: UInt64,
                      sink: AsyncStream<AppsProviderResultRequest>.Continuation) throws {
        let line = try CloudCredentialRelayRefusalTests.line(id: id, op: "cloud.machine.list")
        provider.handle(DaemonEvent.decode(name: AppsProviderCall.eventName, line: line)) { result in _ = sink.yield(result) }
    }

    @Test func anOlderDaemonCannotServeCredentialsWithoutScopeInvalidation() async throws {
        let world = CloudCredentialProviderWorld(), (answers, sink) = AsyncStream<AppsProviderResultRequest>.makeStream()
        let provider = world.provider()
        world.refuseInvalidation = true
        #expect(await register(provider, world) == false)
        try call(provider, id: 1, sink: sink)
        var iterator = answers.makeAsyncIterator()
        let answer = try #require(await iterator.next())
        #expect(!answer.ok && answer.body["code"]?.stringValue == "credential.unavailable")
        #expect(world.registrations == 1 && world.invalidations == 1)
        #expect(world.postCount == 0)
    }

    @Test func aScopeChangeNotifiesEvenWithNoRequestInFlight() async {
        let world = CloudCredentialProviderWorld(), provider = world.provider()
        #expect(await register(provider, world))
        #expect(provider.inFlight == 0)
        await provider.scopeChanged { try await world.invalidate($0) }
        #expect(world.invalidations == 2)
    }

    @Test func aStoppedAnswerCannotRemoveOrAnswerANewConnectionRequestWithTheSameID() async throws {
        let world = CloudCredentialProviderWorld(), provider = world.provider()
        world.holdPosts = true
        let (answers, sink) = AsyncStream<AppsProviderResultRequest>.makeStream()
        var started = world.started.stream.makeAsyncIterator()
        #expect(await register(provider, world))
        try call(provider, id: 1, sink: sink)
        let old = try #require(await started.next())
        let stopped = provider.stop()
        #expect(stopped.count == 1)
        #expect(await register(provider, world))
        try call(provider, id: 1, sink: sink)
        let current = try #require(await started.next())
        world.release(old)
        for task in stopped { await task.value }
        #expect(provider.inFlight == 1)
        world.release(current)
        var iterator = answers.makeAsyncIterator()
        let answer = try #require(await iterator.next())
        #expect(answer.ok && answer.requestID == 1)
    }

    @Test func stoppedConnectionWorkRemainsAvailableForTheSessionDrain() async throws {
        let world = CloudCredentialProviderWorld(), provider = world.provider()
        world.holdPosts = true
        let (_, sink) = AsyncStream<AppsProviderResultRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var started = world.started.stream.makeAsyncIterator()
        #expect(await register(provider, world))
        try call(provider, id: 1, sink: sink)
        let old = try #require(await started.next())
        let disconnected = provider.stop()
        let ending = provider.stop()
        #expect(disconnected.count == 1)
        #expect(ending.count == 1, "sign-out must still join work cancelled by an earlier connection loss")
        world.release(old)
        for task in disconnected { await task.value }
        for task in ending { await task.value }
    }

    @Test func endingASessionBlocksReconnectsAndCredentialCallsUntilTheNextSignIn() async throws {
        let world = CloudCredentialProviderWorld(), provider = world.provider()
        world.holdPosts = true
        let (answers, sink) = AsyncStream<AppsProviderResultRequest>.makeStream(bufferingPolicy: .bufferingNewest(4))
        var started = world.started.stream.makeAsyncIterator()
        var invalidating = world.invalidationStarted.stream.makeAsyncIterator()
        #expect(await register(provider, world))
        try call(provider, id: 1, sink: sink)
        let old = try #require(await started.next())
        // task-owner: ending; joined below after the held invalidation and old HTTP work finish.
        let ending = Task { await provider.endSession { try await world.holdInvalidation($0) } }
        _ = try #require(await invalidating.next())
        #expect(await register(provider, world) == false, "a reconnect cannot reopen the retiring account")
        world.holdPosts = false
        try call(provider, id: 2, sink: sink)
        var iterator = answers.makeAsyncIterator()
        let refused = try #require(await iterator.next())
        #expect(!refused.ok && refused.body["code"]?.stringValue == "credential.unavailable")
        #expect(world.postCount == 1, "the ending session must perform no new credential HTTP")
        world.release(old)
        world.releaseInvalidation()
        await ending.value
        #expect(await register(provider, world) == false, "registration stays closed until a new sign-in")
    }
}

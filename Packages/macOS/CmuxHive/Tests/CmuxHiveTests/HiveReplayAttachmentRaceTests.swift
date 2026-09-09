import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveReplayAttachmentRaceTests {
    @MainActor private final class RetryObservation { var count = 0 }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<10)
    func attachingWhileRefreshOwnsReplayKeepsTheSubscription(_ iteration: Int) async throws {
        let fixture = try HiveSessionRaceFixture()
        try await fixture.connect()
        let client = try #require(fixture.session.client)
        let subscriptionCount = await fixture.transport.sentMethods.filter {
            $0 == "mobile.events.subscribe"
        }.count
        await fixture.transport.holdResponse(to: "mobile.events.subscribe", occurrence: subscriptionCount + 1)
        await fixture.transport.holdResponse(to: "mobile.terminal.replay", occurrence: 1)
        let retries = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let retry = RetryObservation()
        let terminal = HiveRemoteTerminalSession(
            client: client, workspaceID: "ws-1", terminalID: "term-1",
            retryDelay: { _ in
                await MainActor.run { retry.count += 1 }
                for await _ in retries.stream { break }
            }
        )
        defer {
            retries.continuation.finish()
            terminal.detach()
        }
        terminal.attach()
        do {
            try await fixture.transport.waitForMethod("mobile.events.subscribe", count: subscriptionCount + 1)
            terminal.refreshReplay()
            try await fixture.transport.waitForMethod("mobile.terminal.replay")
            await fixture.transport.releaseResponse(to: "mobile.events.subscribe", occurrence: subscriptionCount + 1)
            // An independent RPC allows the released subscription response to
            // cross the real client while the replay response remains gated.
            let barrier = try MobileCoreRPCClient.requestData(method: "test.barrier")
            _ = try await client.sendRequest(barrier)
            await fixture.transport.releaseResponse(to: "mobile.terminal.replay", occurrence: 1)
            try await waitUntil { terminal.phase == .live || retry.count > 0 }
            #expect(retry.count == 0)
            #expect(terminal.phase == .live)
            if terminal.phase == .live {
                terminal.send(text: "after-attach-\(iteration)")
                try await fixture.transport.waitForMethod("mobile.terminal.input")
                #expect(await fixture.transport.sentInputTexts == ["after-attach-\(iteration)"])
            }
        } catch {
            terminal.detach()
            await fixture.session.disconnect()
            throw error
        }
        terminal.detach()
        await fixture.session.disconnect()
    }
}

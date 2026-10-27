import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import os
import Testing

/// `home.server` (dm-group-chat-DESIGN.md section 4.5): the hosted cmux Cloud
/// leases the Stack token as before; a self-hosted server is leased with
/// `auth: "tailscale"` and no token, and the person is who the server says
/// (`cloud-selfhost-info`), with no Stack sign-in at all.
@MainActor
struct CloudServerChoiceTests {
    static let hostedAPI = URL(string: "https://cloud-api.cmux.dev")!
    static let server = URL(string: "http://mini.tail1234.ts.net:7320")!
    static let info = CloudSelfHostInfo(userID: "user_ts_abcdefghijklmnopqrst", login: "me@example.com", displayName: "Me on mini",
                                        serverName: "mini")

    private func link(tokens: FakeLeaseTokens, source: CloudHomeSource) -> HomeCloudLink {
        let lease = HomeCloudLease(tokens: tokens, apiBaseURL: Self.hostedAPI, clientVersion: "1.2.3",
                                   logger: Logger(subsystem: "CmuxNextHomeEngineTests", category: "lease"))
        return HomeCloudLink(lease: lease, source: source, localID: CloudSourceHarness.me.id, stackProjectID: "stack-project")
    }

    @Test func selfHostedLeasesTheServerWithTailscaleAndNoToken() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.answerSelfHost(Self.info)
        let tokens = FakeLeaseTokens(subject: "stack-user-1", signedIn: false)
        let source = CloudHomeSource(me: CloudSourceHarness.me, attachmentCache: CloudSourceHarness.temporaryDirectory())
        let linker = link(tokens: tokens, source: source)
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: nil, displayName: "",
                                              server: .selfHosted(Self.server)))
        await linker.settle()
        let sessions = await daemon.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.apiBaseURL == "http://mini.tail1234.ts.net:7320")
        #expect(sessions.first?.auth == "tailscale")
        #expect(sessions.first?.accessToken == nil)
        #expect(sessions.first?.expiresAt == nil)
        #expect(tokens.asked == 0, "a self-hosted server never asks for a Stack token")
        #expect(source.accountID == Self.info.userID, "the person is who the server says")
        // Ops go out under the server's user.
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("mute-self"),
                                               op: .setMuted(conversation: ConversationID("conv_self"), muted: true)))
        #expect(await daemon.inboxOps.map(\.idempotencyKey) == ["mute-self"])
    }

    @Test func selfHostedEventsOfTheServersUserAreThisAccounts() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.answerSelfHost(Self.info)
        let source = CloudHomeSource(me: CloudSourceHarness.me, attachmentCache: CloudSourceHarness.temporaryDirectory())
        let linker = link(tokens: FakeLeaseTokens(subject: "stack-user-1"), source: source)
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: "stack-user-1", displayName: "Me",
                                              server: .selfHosted(Self.server)))
        await linker.settle()
        let state = CloudSubscriptionState(scope: "inbox", state: "live", account: Self.info.userID)
        #expect(CloudHomeSource.isForAccount(.subscriptionState(state), cloudID: source.accountID))
    }

    @Test func hostedStillLeasesTheStackToken() async throws {
        let daemon = FakeCloudDaemon()
        let tokens = FakeLeaseTokens(subject: "stack-user-1")
        let source = CloudHomeSource(me: CloudSourceHarness.me, attachmentCache: CloudSourceHarness.temporaryDirectory())
        let linker = link(tokens: tokens, source: source)
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: "stack-user-1", displayName: "Me"))
        await linker.settle()
        let sessions = await daemon.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.apiBaseURL == "https://cloud-api.cmux.dev")
        #expect(sessions.first?.auth == nil)
        #expect(sessions.first?.accessToken?.isEmpty == false)
        #expect(sessions.first?.expiresAt == tokens.expiry * 1000)
        #expect(tokens.asked == 1)
        #expect(source.accountID == "user_stack-user-1")
    }

    @Test func switchingToSelfHostedReplacesTheHostedLease() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.answerSelfHost(Self.info)
        let source = CloudHomeSource(me: CloudSourceHarness.me, attachmentCache: CloudSourceHarness.temporaryDirectory())
        let linker = link(tokens: FakeLeaseTokens(subject: "stack-user-1"), source: source)
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: "stack-user-1", displayName: "Me"))
        await linker.settle()
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: "stack-user-1", displayName: "Me",
                                              server: .selfHosted(Self.server)))
        await linker.settle()
        #expect(await daemon.sessions.map(\.auth) == [nil, "tailscale"])
        #expect(source.accountID == Self.info.userID)
    }

    @Test func aServerThatIsNotSelfHostedLeavesNoLease() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.answerSelfHost(nil)
        let source = CloudHomeSource(me: CloudSourceHarness.me, attachmentCache: CloudSourceHarness.temporaryDirectory())
        let linker = link(tokens: FakeLeaseTokens(subject: "stack-user-1"), source: source)
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: nil, displayName: "",
                                              server: .selfHosted(Self.server)))
        #expect(await daemon.clears >= 1, "a failed self-hosted lease is cleared, never kept half set")
        #expect(source.accountID == nil)
    }

    @Test func anIPv6TailnetOriginKeepsItsBrackets() {
        let url = URL(string: "http://[fd7a:115c:a1e0::1]:7320")!
        #expect(HomeCloudLease.origin(url) == "http://[fd7a:115c:a1e0::1]:7320")
        #expect(HomeCloudLease.origin(Self.hostedAPI) == "https://cloud-api.cmux.dev")
    }
}

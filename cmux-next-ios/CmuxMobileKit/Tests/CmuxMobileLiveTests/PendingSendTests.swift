import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster". A message sent in a chat whose Mac has not sent its tree yet (a relaunch, the link
/// still opening) is held for the chat's real source, as a send on a loaded chat rides out a blip
/// (`AcpmuxSessionSource.heldPromptWindow`). Before, it bounced at once: the draft came back with
/// "Connecting to <Mac>… Send again once the chat loads."
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PendingSendTests {
    private func pending() -> PendingAgentSource {
        let summary = AgentSessionSummary(id: "s3", name: "chat", harness: "claude", agentName: "Claude", cwd: "~",
                                          workspaceTitle: "w", macName: "Studio", macID: "m1")
        return PendingAgentSource(summary: summary, cache: nil, keptKey: nil) { _ in }
    }

    private func prompt(_ text: String, id: String) -> AgentClientIntent {
        .prompt(text: text, attachments: [], steer: false, promptID: id, resend: false)
    }

    private static func isNotSent(_ event: AgentSessionEvent) -> Bool {
        if case .promptNotSent = event { true } else { false }
    }

    /// The prompt, then a cancel (which has nothing to act on and says so in both versions):
    /// the first event the chat gets is the cancel's, not the prompt coming back.
    @Test func aSendBeforeTheChatLoadsDoesNotBounce() async throws {
        let source = pending()
        var events = source.events().makeAsyncIterator()
        source.send(prompt("hello", id: "p1"))
        source.send(.cancel)
        let first = await events.next()
        #expect(first.map(Self.isNotSent) == false, "the draft came back at once: \(String(describing: first))")
    }

    /// A held prompt that waits past the window comes back to the composer with why, as
    /// `AcpmuxSessionSource` returns a prompt held past its window.
    @Test func aHeldPromptPastTheWindowComesBackWithWhy() async throws {
        let source = pending()
        source.holdWindow = .seconds(3600)
        var events = source.events().makeAsyncIterator()
        source.send(prompt("hello", id: "p1"))
        let sentAt = try #require(source.held.first?.at)
        source.expire(sentAt: sentAt)
        let first = await events.next()
        guard case .promptNotSent(let text, _, let promptID, let reason)? = first else {
            Issue.record("expected the prompt back, got \(String(describing: first))")
            return
        }
        #expect(text == "hello" && promptID == "p1")
        #expect(reason == "Not sent: Studio is offline.")
        #expect(source.held.isEmpty)
    }

    /// The chat's next source gets the held prompts, in order and with their send times, and
    /// the loading source no longer returns them.
    @Test func theNextSourceGetsTheHeldPromptsInOrder() async throws {
        let source = pending()
        source.holdWindow = .seconds(3600)
        var events = source.events().makeAsyncIterator()
        source.send(prompt("one", id: "p1"))
        source.send(prompt("two", id: "p2"))
        let sentAt = try #require(source.held.first?.at)
        let taken = source.takeHeld()
        #expect(taken.map(\.intent) == [prompt("one", id: "p1"), prompt("two", id: "p2")])
        #expect(taken.first?.at == sentAt)
        source.expire(sentAt: sentAt)
        source.send(.cancel)
        let first = await events.next()
        #expect(first.map(Self.isNotSent) == false, "a handed-over prompt came back: \(String(describing: first))")

        // A loading source that takes them over keeps their age (one window in all).
        let next = pending()
        next.holdWindow = .seconds(3600)
        for (intent, at) in taken { next.hold(intent, since: at) }
        #expect(next.held.map(\.at) == taken.map(\.at))
    }

    private func coordinator() -> LiveCoordinator {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-pending-\(UUID().uuidString)")
        let secrets = MemorySecretStore()
        return LiveCoordinator(
            store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory()),
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: "user-a", deviceName: "iPhone", transport: .webRTC, dialer: MockDialer(fail: true),
            feedStore: FeedStore(items: []),
            keys: PhoneKeys(userID: "user-a", service: "test.pending.\(UUID())", store: secrets, enclave: false),
            snapshots: LiveSnapshotStore(directory: directory), secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json"))
        )
    }

    /// The chat's store went while the person was elsewhere (the Mac's tree bound the tab, its
    /// kept records opened it) and a prompt is still held: the chat gets its next store at once,
    /// so the prompt is sent or comes back with why. Before, nothing built it until the chat was
    /// opened again, and the held prompt expired into a store that no longer existed (lost).
    @Test func aHeldPromptKeepsAChatWhenItsStoreIsRebuiltOffScreen() async throws {
        let live = coordinator()
        defer { live.stop() }
        let source = pending()
        source.holdWindow = .seconds(3600)
        source.send(prompt("hello", id: "p1"))
        live.pendingSources[AgentSessionDirectory.key(id: "s3", macID: "m1")] = source
        AgentSessionDirectory.shared.invalidate(id: "s3", macID: "m1")
        defer { AgentSessionDirectory.shared.invalidate(id: "s3", macID: "m1") }

        live.chatSessionChanged(id: "s3", macID: "m1")

        #expect(AgentSessionDirectory.shared.existingStore(id: "s3", macID: "m1") != nil,
                "the held prompt has no chat to be sent from or come back to")
        #expect(source.held.isEmpty, "the held prompt stayed on the dropped source")
    }
}
#endif

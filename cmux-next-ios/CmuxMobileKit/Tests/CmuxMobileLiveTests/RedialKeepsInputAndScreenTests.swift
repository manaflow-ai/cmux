import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-22: "me swiping up to go to another app then back to the ios
/// cmux internal app... there's lag when coming back. lag to interaction.
/// percieved interaction. we need to do better here. shit shouldnt somehow
/// instantly dissipate after i navigate away for like one second."
///
/// While the link is being redialed after the app comes back, a tap on a
/// Feed approval waits for the new link and goes there (checked again), and
/// the workspace list keeps its activity times, marked stale, until the new
/// link answers.
@MainActor
@Suite struct RedialKeepsInputAndScreenTests {
    /// Which connection the fake Mac's daemon channel is bound to (nil: none).
    @MainActor
    final class Link {
        var serial: Int?
    }

    static func noLink() -> LinkError { LinkError(code: "no-link", message: "Not connected to the Mac") }

    /// The approval card on connection 1, then the link goes down: requests and
    /// keys throw `no-link` (as `LiveCoordinator.wire` does) until `link.serial`
    /// names their connection.
    static func approvalDuringARedial() async throws -> (TerminalFeed, TerminalQuestionFeedTests.Daemon, Link, FeedItem, ACPPermissionRequest) {
        let (store, feed, daemon) = TerminalApprovalFeedTests.make(rows: [TerminalApprovalFeedTests.row()])
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        let item = try #require(store.item(id: "term-mac-ntf_7"))
        guard case .permission(let request) = item.kind else {
            Issue.record("no permission card")
            throw CancellationError()
        }
        let link = Link()
        feed.request = { command, params, connection in
            guard connection == link.serial else { throw Self.noLink() }
            return daemon.respond(command, params)
        }
        feed.type = { surface, bytes, connection in
            guard connection == link.serial else { throw Self.noLink() }
            daemon.typed.append((surface, String(decoding: bytes, as: UTF8.self)))
        }
        return (feed, daemon, link, item, request)
    }

    /// Before: the tap failed at once with "Couldn't check the approval on the
    /// Mac" (the ledger read threw `no-link`), and nothing was typed.
    @Test func anApprovalTappedDuringARedialIsTypedOnceOnTheNextLink() async throws {
        let (feed, daemon, link, item, request) = try await Self.approvalDuringARedial()
        // As long as the keyboard holds its keys for a redial.
        #expect(feed.linkWait == .seconds(DaemonTerminalSession.inputHoldLimit))
        let answer = Task { try await feed.respond(item, request: request, option: TerminalApproval.allowOnce) }
        await TerminalFeedTests.settle { feed.waitsForLink }
        #expect(feed.waitsForLink)
        #expect(daemon.typed.isEmpty)
        // The redial lands: the next connection's tree, then its ledger.
        link.serial = 2
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: 2)
        try await answer.value
        #expect(daemon.typed.map(\.0) == [1])
        #expect(daemon.typed.map(\.1) == ["1"])
        #expect(daemon.reads == 1, "the screen was checked again on the new link, once")
        #expect(!feed.waitsForLink)
    }

    /// The link does not come back within the hold: the card says so and
    /// nothing is typed, then or later.
    @Test func anApprovalPastTheHoldSaysNotConnectedAndTypesNothing() async throws {
        let (feed, daemon, link, item, request) = try await Self.approvalDuringARedial()
        feed.linkWait = .milliseconds(50)
        await #expect(throws: TerminalFeed.QuestionRefused(message: FeedStore.notConnectedMessage)) {
            try await feed.respond(item, request: request, option: TerminalApproval.allowOnce)
        }
        #expect(!feed.waitsForLink)
        link.serial = 2
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: 2)
        await TerminalFeedTests.drain()
        #expect(daemon.typed.isEmpty)
    }

    /// Before: `bind(nil)` (the link dropped while the app was away) cleared
    /// every surface's activity time, so the list's "active" times were lost
    /// until each surface spoke again.
    @Test func aRedialKeepsActivityMarkedStaleUntilTheNewLinkAnswers() async throws {
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        let first = KnownDaemonChannel(workspaces: 3, advertisesKnown: false)
        await sync.bind(first, macID: "mac")
        #expect(sync.tree?.workspaces.count == 3)
        #expect(!sync.isStale)
        sync.handle(.titleChanged(surface: 1, title: "vim"))
        let seen = try #require(sync.activity[1])

        // The link goes with the app: what is shown stays, marked stale.
        await sync.bind(nil, macID: "")
        #expect(sync.isStale)
        #expect(sync.activity[1] == seen)
        #expect(sync.tree?.workspaces.count == 3)

        // The redial to the same Mac answers: no longer stale, the times kept.
        let second = KnownDaemonChannel(workspaces: 3, advertisesKnown: false)
        defer { second.finish() }
        await sync.bind(second, macID: "mac")
        #expect(!sync.isStale)
        #expect(sync.activity[1] == seen)
        #expect(sync.tree?.workspaces.count == 3)

        // Another Mac never inherits them.
        let other = KnownDaemonChannel(workspaces: 2, advertisesKnown: false)
        defer { other.finish() }
        await sync.bind(other, macID: "other")
        #expect(sync.activity[1] == nil)
        await sync.bind(nil, macID: "")
    }
}

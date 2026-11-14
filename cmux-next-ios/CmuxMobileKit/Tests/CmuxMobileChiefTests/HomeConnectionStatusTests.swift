import Testing
@testable import CmuxMobileChief

/// CMUX-489, reworked 2026-11-13: Home says its list is not live in the Workspaces tab's words
/// (the navigation subtitle over kept rows, Workspaces' empty states without them), not a card.
@Suite struct HomeConnectionStatusTests {
    @Test func aLiveListSaysNothing() {
        #expect(HomeConnectionStatus.make(linkDown: false, macOnline: true, failed: false, retrying: false, macName: "Studio") == nil)
    }

    @Test func aDroppedLinkMarksTheKeptRowsAsWorkspacesDoes() throws {
        let status = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: true, failed: false, retrying: false, macName: "Studio"))
        #expect(status.kind == .unreachable)
        #expect(status.subtitle == "Offline · last known")
        let empty = try #require(status.empty)
        #expect(empty.title == "Can't connect to Studio")
        #expect(empty.message == "Studio is online, but this iPhone can't reach it.")
        #expect(empty.canRetry)
    }

    @Test func anOfflineMacHasNothingToDial() throws {
        let status = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: false, failed: true, retrying: false, macName: "Studio"))
        #expect(status.kind == .macOffline)
        let empty = try #require(status.empty)
        #expect(empty.title == "Studio is offline")
        #expect(empty.symbol == "moon.zzz")
        #expect(!empty.canRetry)
    }

    @Test func aFailedReadNeverShowsTheRawError() throws {
        let status = try #require(HomeConnectionStatus.make(linkDown: false, macOnline: true, failed: true, retrying: false, macName: nil))
        #expect(status.kind == .failed)
        #expect(status.subtitle == "Couldn't refresh · last known")
        let empty = try #require(status.empty)
        #expect(empty.title == "Couldn't load conversations")
        #expect(empty.message == "your Mac didn't answer. It tries again on its own." || empty.message.hasSuffix("didn't answer. It tries again on its own."))
    }

    @Test func aRetryKeepsItsStateAndSaysUpdating() throws {
        // The state under the retry stays (no flash to another empty state); Retry spins.
        let status = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: true, failed: false, retrying: true, macName: "Studio"))
        #expect(status.kind == .unreachable)
        #expect(status.isRetrying)
        #expect(status.subtitle == "Updating…")
    }

    @Test func aRetryAfterTheLinkCameBackConnects() throws {
        // Reconnecting clears the dropped link before the read answers.
        let status = try #require(HomeConnectionStatus.make(linkDown: false, macOnline: true, failed: false, retrying: true, macName: "Studio"))
        #expect(status.kind == .connecting)
        #expect(status.empty == nil)
        #expect(HomeConnectionStatus.connectingTitle(macName: "Studio") == "Connecting to Studio…")
    }
}

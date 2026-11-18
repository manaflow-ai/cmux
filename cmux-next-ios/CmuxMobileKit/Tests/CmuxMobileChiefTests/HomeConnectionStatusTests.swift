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
        #expect(status.detail == "Offline · last known")
        let empty = try #require(status.empty)
        #expect(empty.title == "Can't connect to Studio")
        #expect(empty.message == "Studio is online, but this iPhone can't reach it.")
        #expect(empty.canRetry)
        #expect(empty.symbol == "desktopcomputer.trianglebadge.exclamationmark")
    }

    @Test func anOfflineMacHasNothingToDial() throws {
        let status = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: false, failed: true, retrying: false, macName: "Studio"))
        #expect(status.kind == .macOffline)
        let empty = try #require(status.empty)
        #expect(empty.title == "Studio is offline")
        #expect(empty.symbol == "moon.zzz")
        #expect(!empty.canRetry)
    }

    @Test func aFailedReadSaysItInWorkspacesWords() throws {
        let status = try #require(HomeConnectionStatus.make(linkDown: false, macOnline: true, failed: true, retrying: false, macName: "Studio"))
        #expect(status.kind == .failed)
        #expect(status.detail == "Couldn't refresh · last known")
        let empty = try #require(status.empty)
        #expect(empty.title == "Couldn't load conversations")
        #expect(empty.message == "Studio didn't answer. It tries again on its own.")
    }

    @Test func anUnnamedMacStartsASentenceCapitalized() throws {
        let asleep = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: false, failed: false, retrying: false, macName: nil))
        #expect(asleep.empty?.title == "Your Mac is offline")
        let unreachable = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: true, failed: false, retrying: false, macName: nil))
        #expect(unreachable.empty?.title == "Can't connect to your Mac")
        #expect(unreachable.empty?.message == "Your Mac is online, but this iPhone can't reach it.")
    }

    @Test func aRetryKeepsItsStateAndSaysUpdating() throws {
        // The state under the retry stays (no flash to another empty state); Retry spins.
        let status = try #require(HomeConnectionStatus.make(linkDown: true, macOnline: true, failed: false, retrying: true, macName: "Studio"))
        #expect(status.kind == .unreachable)
        #expect(status.isRetrying)
        #expect(status.detail == "Updating…")
    }

    @Test func aRetryAfterTheLinkCameBackConnects() throws {
        // Reconnecting clears the dropped link before the read answers.
        let status = try #require(HomeConnectionStatus.make(linkDown: false, macOnline: true, failed: false, retrying: true, macName: "Studio"))
        #expect(status.kind == .connecting)
        #expect(status.empty == nil)
        #expect(HomeConnectionStatus.connectingTitle(macName: "Studio") == "Connecting to Studio…")
    }
}

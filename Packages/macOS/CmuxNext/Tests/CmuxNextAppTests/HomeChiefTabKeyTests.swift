import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The chief tab's creation key: a retry after a lost reply reuses it, a
/// connect while the chief tab is open creates nothing, and a creation after
/// the chief tab was closed takes a new key, so the store never re-creates a
/// closed tab under its old browser id.
@MainActor @Suite struct HomeChiefTabKeyTests {
    /// Records each create's key; `fail` decides a send's error by its index.
    final class Sends {
        var keys: [String] = []
        var fail: (Int) -> (any Error)? = { _ in nil }
        func send(_ key: String) throws {
            keys.append(key)
            if let error = fail(keys.count - 1) { throw error }
        }
    }

    @Test func aRetryBeforeTheTabIsSeenReusesTheKey() {
        let key = HomeChiefTabKey()
        let first = key.forCreate()
        #expect(key.forCreate() == first)
    }

    @Test func aCreationAfterTheTabWasSeenTakesANewKey() {
        let key = HomeChiefTabKey()
        let first = key.forCreate()
        key.settle()
        let second = key.forCreate()
        #expect(second != first)
        key.settle()
        #expect(key.forCreate() != second)
    }

    @Test func keysAreNeverTheRetiredFixedKey() {
        let key = HomeChiefTabKey()
        #expect(key.forCreate() != "home-chief-tab")
    }

    /// Open chief tab: reconnects and relaunches create nothing. Closed: the
    /// next connect creates one tab under a new key.
    @Test func reconnectKeepsTheLiveTabAndAClosedTabGetsANewKey() async throws {
        let key = HomeChiefTabKey()
        let sends = Sends()
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(try await key.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(try await key.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(sends.keys.count == 1, "a connect with the chief tab open must not create a tab")
        // A relaunch starts with a fresh key value and still creates nothing while the tab is open.
        let relaunched = HomeChiefTabKey()
        #expect(try await relaunched.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(sends.keys.count == 1)
        // The tab was closed: the next connect creates one tab under a new key.
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(sends.keys.count == 2)
        #expect(sends.keys[1] != sends.keys[0])
    }

    /// A lost reply keeps the key, so the next connect replays the same create.
    @Test func aLostReplyKeepsTheKeyForTheRetry() async throws {
        let key = HomeChiefTabKey()
        let sends = Sends()
        sends.fail = { $0 == 0 ? DaemonError.connectionClosed(reason: "lost") : nil }
        await #expect(throws: DaemonError.self) { try await key.ensure(chiefTabOpen: false) { try sends.send($0) } }
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(sends.keys.count == 2)
        #expect(sends.keys[0] == sends.keys[1])
    }

    /// The pending key's tab was created and closed: the refusal is not
    /// shown; one retry under a new key creates the tab.
    @Test func aKeyClosedRefusalRetriesOnceWithANewKey() async throws {
        let key = HomeChiefTabKey()
        let sends = Sends()
        sends.fail = { index in
            index == 0 ? DaemonError.command(cmd: "new-conversation-tab", message: "closed",
                                             code: HomeChiefTabKey.keyClosedCode) : nil
        }
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(sends.keys.count == 2)
        #expect(sends.keys[0] != sends.keys[1])
    }

    /// Two connects overlap: the second starts while the first still waits
    /// for its reply. Both send the one pending key, so the store replays one
    /// tab instead of creating two.
    @Test func anOverlappingConnectSendsThePendingKey() async throws {
        let key = HomeChiefTabKey()
        var overlapped: String?
        var sent: String?
        #expect(try await key.ensure(chiefTabOpen: false) { first in
            sent = first
            overlapped = key.forCreate()
        })
        #expect(overlapped == sent)
        #expect(key.forCreate() != sent, "the creation settled: the next one takes a new key")
    }

    /// The person moved the chief tab out of the home: it is still open, so
    /// a connect creates no second chief tab.
    @Test func aChiefTabMovedOutOfTheHomeStillCounts() throws {
        let tab = #"{"kind":"conversation","name":"","surface":7,"dead":false,"browser_renderer":"frontend","conversation":{"conversation":"conv_01CHIEF","owner":"local"}}"#
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[
        {"active":false,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a01","name":"Home","kind":"home","screens":[]},
        {"active":true,"id":2,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02","name":"work",
        "screens":[{"active":true,"id":3,"layout":{"pane":4,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":4,"name":null,
        "tabs":[\(tab)]}]}]}]}
        """
        let store = DaemonStore()
        store.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8)))
        #expect(HomeChiefTabKey.isOpen(chief: "conv_01CHIEF", in: store.workspaces))
        #expect(!HomeChiefTabKey.isOpen(chief: "conv_01OTHER", in: store.workspaces))
    }
}

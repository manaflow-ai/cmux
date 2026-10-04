import CmuxNextDaemon
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
        var key = HomeChiefTabKey()
        let first = key.forCreate()
        #expect(key.forCreate() == first)
    }

    @Test func aCreationAfterTheTabWasSeenTakesANewKey() {
        var key = HomeChiefTabKey()
        let first = key.forCreate()
        key.settle()
        let second = key.forCreate()
        #expect(second != first)
        key.settle()
        #expect(key.forCreate() != second)
    }

    @Test func keysAreNeverTheRetiredFixedKey() {
        var key = HomeChiefTabKey()
        #expect(key.forCreate() != "home-chief-tab")
    }

    /// Open chief tab: reconnects and relaunches create nothing. Closed: the
    /// next connect creates one tab under a new key.
    @Test func reconnectKeepsTheLiveTabAndAClosedTabGetsANewKey() async throws {
        var key = HomeChiefTabKey()
        let sends = Sends()
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(try await key.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(try await key.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(sends.keys.count == 1, "a connect with the chief tab open must not create a tab")
        // A relaunch starts with a fresh key value and still creates nothing while the tab is open.
        var relaunched = HomeChiefTabKey()
        #expect(try await relaunched.ensure(chiefTabOpen: true) { try sends.send($0) } == false)
        #expect(sends.keys.count == 1)
        // The tab was closed: the next connect creates one tab under a new key.
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(sends.keys.count == 2)
        #expect(sends.keys[1] != sends.keys[0])
    }

    /// A lost reply keeps the key, so the next connect replays the same create.
    @Test func aLostReplyKeepsTheKeyForTheRetry() async throws {
        var key = HomeChiefTabKey()
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
        var key = HomeChiefTabKey()
        let sends = Sends()
        sends.fail = { index in
            index == 0 ? DaemonError.command(cmd: "new-conversation-tab", message: "closed",
                                             code: HomeChiefTabKey.keyClosedCode) : nil
        }
        #expect(try await key.ensure(chiefTabOpen: false) { try sends.send($0) })
        #expect(sends.keys.count == 2)
        #expect(sends.keys[0] != sends.keys[1])
    }
}

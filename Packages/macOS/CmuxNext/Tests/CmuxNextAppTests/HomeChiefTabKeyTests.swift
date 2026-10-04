import Testing
@testable import CmuxNextApp

/// The chief tab's creation key: a retry after a lost reply reuses it, and a
/// creation after the chief tab was seen (and then closed) takes a new key,
/// so the store never re-creates a closed tab under its old browser id.
@Suite struct HomeChiefTabKeyTests {
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
}

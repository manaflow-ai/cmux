import Testing
@testable import CmuxMobileChief

/// iOS release bar read-back, 2026-11-22, shot 04: Home said "Loading conversations…" with a
/// spinner forever on the mock, where no Mac link ever opens. The same note never ended for an
/// account whose every Mac is offline. The note waits only on a list that can still come.
struct HomeListNoteTests {
    private func note(live: Bool, macsKnown: Bool, anyOnline: Bool) -> HomeListNote {
        HomeListNote.make(rows: nil, homeMacID: nil,
                          macsMayExist: HomeListNote.macsMayAnswer(live: live, macsKnown: macsKnown, anyOnline: anyOnline),
                          searching: false, failing: false)
    }

    @Test func theMockNeverSaysLoading() {
        #expect(note(live: false, macsKnown: false, anyOnline: false) == .none)
        #expect(note(live: false, macsKnown: true, anyOnline: true) == .none)
    }

    @Test func aLiveAccountLoadsWhileItsMacsAreUnknownOrOneIsOnline() {
        #expect(note(live: true, macsKnown: false, anyOnline: false) == .loading)
        #expect(note(live: true, macsKnown: true, anyOnline: true) == .loading)
    }

    @Test func everyMacOfflineSaysNothing() {
        #expect(note(live: true, macsKnown: true, anyOnline: false) == .none)
    }

    @Test func aChosenMacStillConnects() {
        #expect(HomeListNote.make(rows: nil, homeMacID: "mac-1", macsMayExist: false,
                                  searching: false, failing: false) == .connecting)
    }
}

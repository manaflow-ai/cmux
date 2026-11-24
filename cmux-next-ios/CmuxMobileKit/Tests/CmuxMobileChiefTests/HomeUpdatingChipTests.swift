import Testing
@testable import CmuxMobileChief

/// The user, 2026-11-23: "why is there an updating spinner in the bottom when reconnecting already
/// exists at the top? seems redundant ... only reconnecting shows." Home's bottom "Updating" chip
/// shows only when kept rows wait for the fresh list and nothing else says so.
@Suite struct HomeUpdatingChipTests {
    @Test func showsAloneWhileKeptRowsUpdateOverALiveLink() {
        #expect(HomeUpdatingChip.shows(note: .updating, bannerShows: false, pullRefreshing: false))
    }

    @Test func reconnectingAtTheTopHidesIt() {
        #expect(!HomeUpdatingChip.shows(note: .updating, bannerShows: true, pullRefreshing: false))
    }

    @Test func aPullToRefreshHidesIt() {
        #expect(!HomeUpdatingChip.shows(note: .updating, bannerShows: false, pullRefreshing: true))
        #expect(!HomeUpdatingChip.shows(note: .updating, bannerShows: true, pullRefreshing: true))
    }

    @Test func otherNotesNeverShowIt() {
        for note in [HomeListNote.none, .connecting, .loading] {
            #expect(!HomeUpdatingChip.shows(note: note, bannerShows: false, pullRefreshing: false))
        }
    }
}

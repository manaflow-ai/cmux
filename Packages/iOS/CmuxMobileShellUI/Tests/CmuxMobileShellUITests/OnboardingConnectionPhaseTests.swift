#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingConnectionPhaseTests {
    @Test func unresolvedAutomaticDiscoveryShowsSearching() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: false
        ) == .searching)
    }

    @Test func activeAutomaticDiscoveryShowsSearching() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: true,
            didFinishSearch: true
        ) == .searching)
    }

    @Test func completedSearchWithoutMacRevealsFallback() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: true
        ) == .fallback)
    }

    @Test func connectedMacAlwaysShowsReady() {
        #expect(OnboardingConnectionPhase(
            isMacReady: true,
            isSearching: true,
            didFinishSearch: false
        ) == .ready)
    }

    @Test func replayCanDeclareNoSearchPending() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: true
        ) == .fallback)
    }
}
#endif

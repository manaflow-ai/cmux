import CmuxMobileModel
import Testing
@testable import CmuxMobileWorkspaces

/// CMUX-49: the Workspaces page through a cold launch, a cached launch and
/// their refreshes. One state at a time; a cached list is never hidden behind
/// loading or an error; nothing claims "no Macs" before the Macs are known.
@Suite struct WorkspacesLaunchStateTests {
    private func state(_ team: AppStore.LoadState, macs: Bool, workspaces: Bool, offline: Bool = false) -> WorkspacesLaunchState {
        WorkspacesLaunchState.resolve(team: team, hasMacs: macs, hasWorkspaces: workspaces, isOffline: offline)
    }

    @Test func coldLaunchLoadsThenShowsTheList() {
        #expect(state(.loading, macs: false, workspaces: false) == .firstLoad(offline: false))
        // The Macs are known before their lists: the list's own per-Mac placeholders take over.
        #expect(state(.loaded, macs: true, workspaces: false) == .content(refreshFailed: false))
        #expect(state(.loaded, macs: true, workspaces: true) == .content(refreshFailed: false))
    }

    @Test func coldLaunchNeverSaysNoMacsWhileLoading() {
        for offline in [false, true] {
            let loading = state(.loading, macs: false, workspaces: false, offline: offline)
            #expect(loading != .noMacs)
            #expect(loading == .firstLoad(offline: offline))
        }
        // Only a loaded team with no Mac is the connect-a-Mac page.
        #expect(state(.loaded, macs: false, workspaces: false) == .noMacs)
    }

    @Test func cachedLaunchShowsItsRowsAtOnce() {
        // A snapshot's Macs and rows while the team refreshes: the list, not placeholders.
        #expect(state(.loading, macs: true, workspaces: true) == .content(refreshFailed: false))
    }

    @Test func failedRefreshKeepsTheCachedRows() {
        #expect(state(.failed, macs: true, workspaces: true) == .content(refreshFailed: true))
        #expect(state(.failed, macs: true, workspaces: true, offline: true) == .content(refreshFailed: true))
    }

    @Test func failedFirstLoadIsTheErrorPage() {
        #expect(state(.failed, macs: false, workspaces: false) == .failed(offline: false))
        #expect(state(.failed, macs: false, workspaces: false, offline: true) == .failed(offline: true))
    }

    @Test func failedRefreshWithKnownMacsKeepsTheList() {
        // The rows come from the Macs' links: their per-Mac states, not the error page.
        #expect(state(.failed, macs: true, workspaces: false) == .content(refreshFailed: true))
    }

    @Test func updatingSubtitleOnlyOverRows() {
        #expect(!WorkspacesLaunchState.firstLoad(offline: false).allowsUpdatingSubtitle)
        #expect(!WorkspacesLaunchState.failed(offline: false).allowsUpdatingSubtitle)
        #expect(!WorkspacesLaunchState.noMacs.allowsUpdatingSubtitle)
        #expect(!WorkspacesLaunchState.content(refreshFailed: true).allowsUpdatingSubtitle)
        #expect(WorkspacesLaunchState.content(refreshFailed: false).allowsUpdatingSubtitle)
    }
}

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

    @Test func cachedRowsDrawNoPlaceholderRows() {
        // Leo, 2026-11-24: "wer need to chase all these placeholders doen and prevent them".
        // A launch or a team switch with cached rows: the rows, never placeholders over them.
        let cached = state(.loading, macs: true, workspaces: true)
        #expect(!cached.showsPlaceholderRows(hasMacs: true, listLoading: false, hasMacLines: false))
        #expect(!cached.showsPlaceholderRows(hasMacs: true, listLoading: false, hasMacLines: true))
        let failed = state(.failed, macs: true, workspaces: true)
        #expect(!failed.showsPlaceholderRows(hasMacs: true, listLoading: false, hasMacLines: false))
        // A Mac line on screen: the page's rows never cover it (the list's own go below it).
        #expect(!cached.showsPlaceholderRows(hasMacs: true, listLoading: true, hasMacLines: true))
    }

    @Test func placeholderRowsOnlyWhenNothingWasEverListed() {
        // An install that never loaded the team: the labelled placeholder rows.
        #expect(state(.loading, macs: false, workspaces: false).showsPlaceholderRows(hasMacs: false, listLoading: false, hasMacLines: false))
        // Macs known, no row and no Mac line yet.
        #expect(state(.loaded, macs: true, workspaces: false).showsPlaceholderRows(hasMacs: true, listLoading: true, hasMacLines: false))
        // No Mac: the connect page, not placeholders; a failed first load: the error page.
        #expect(!WorkspacesLaunchState.noMacs.showsPlaceholderRows(hasMacs: false, listLoading: false, hasMacLines: false))
        #expect(!WorkspacesLaunchState.failed(offline: true).showsPlaceholderRows(hasMacs: false, listLoading: false, hasMacLines: false))
    }
}

#if os(iOS)
import Testing
@testable import CmuxMobileWorkspaces

/// A Mac's fold line is a button only when a tap does something, and is never a disabled
/// (grayed) button while a link comes back (Leo, 2026-11-24: "the entire thing is somehow grayed
/// out and I can't interact with anything at all"). Before, it was `.disabled(...)` when forced
/// open or when a not-linked Mac had no way to link.
@MainActor @Suite struct FoldLineTapTests {
    @Test func anOfflineMacUnfoldsItsLastKnownRows() {
        #expect(WorkspacesList.foldTap(.offline, isForcedOpen: false, canReconnect: false) == .toggle)
        #expect(WorkspacesList.foldTap(.offline, isForcedOpen: false, canReconnect: true) == .toggle)
    }

    @Test func aNotLinkedOrFailedMacLinksOnATap() {
        #expect(WorkspacesList.foldTap(.notConnected, isForcedOpen: false, canReconnect: true) == .reconnect)
        #expect(WorkspacesList.foldTap(.failed("no answer"), isForcedOpen: false, canReconnect: true) == .reconnect)
    }

    @Test func withNothingToDoTheLineIsTextNotADisabledButton() {
        // Forced open (filtered to the Mac, searching, every Mac asleep): its rows show already.
        #expect(WorkspacesList.foldTap(.offline, isForcedOpen: true, canReconnect: true) == nil)
        // No way to link from here (no live coordinator).
        #expect(WorkspacesList.foldTap(.notConnected, isForcedOpen: false, canReconnect: false) == nil)
        #expect(WorkspacesList.foldTap(.failed("x"), isForcedOpen: false, canReconnect: false) == nil)
    }
}
#endif

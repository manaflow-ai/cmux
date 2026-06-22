import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@MainActor
@Suite("SplitLifecycleCoordinator")
struct SplitLifecycleCoordinatorTests {
    @Test("starts idle, matching the legacy stored-property defaults")
    func initialState() {
        let model = SplitLifecycleCoordinator()
        #expect(model.postCloseSelectTabId.isEmpty)
        #expect(model.postCloseClearSplitZoomTabIds.isEmpty)
        #expect(model.pendingPaneClosePanelIds.isEmpty)
    }

    /// `didClosePane` reads the recorded panel ids exactly once and removes them
    /// (legacy `pendingPaneClosePanelIds.removeValue(forKey:) ?? []`).
    @Test("recordPaneClosePanelIds then consume roundtrips and clears the entry")
    func paneClosePanelIdsRoundtrip() {
        let model = SplitLifecycleCoordinator()
        let pane = UUID()
        let panelA = UUID()
        let panelB = UUID()
        model.recordPaneClosePanelIds([panelA, panelB], forPane: pane)

        #expect(model.consumePaneClosePanelIds(forClosed: pane) == [panelA, panelB])
        // Second read defaults to empty; the entry was removed (single-shot).
        #expect(model.consumePaneClosePanelIds(forClosed: pane) == [])
        #expect(model.pendingPaneClosePanelIds.isEmpty)
    }

    /// A pane whose close never recorded ids consumes to empty (legacy `?? []`).
    @Test("consumePaneClosePanelIds returns [] for an unrecorded pane")
    func paneClosePanelIdsMissing() {
        let model = SplitLifecycleCoordinator()
        #expect(model.consumePaneClosePanelIds(forClosed: UUID()) == [])
    }

    /// A vetoed pane-close discards its recorded ids before the close runs
    /// (legacy `pendingPaneClosePanelIds.removeValue(forKey:)` on the
    /// confirmation-required veto).
    @Test("clearPaneClosePanelIds discards a recorded pane entry")
    func paneClosePanelIdsClearOnVeto() {
        let model = SplitLifecycleCoordinator()
        let pane = UUID()
        model.recordPaneClosePanelIds([UUID()], forPane: pane)

        model.clearPaneClosePanelIds(forPane: pane)
        #expect(model.pendingPaneClosePanelIds.isEmpty)
        #expect(model.consumePaneClosePanelIds(forClosed: pane) == [])
    }

    /// `didCloseTab` reads the recorded selection target exactly once and
    /// removes it (legacy `postCloseSelectTabId.removeValue(forKey:)`).
    @Test("consumePostCloseSelectTabId removes and returns the recorded target")
    func consumeSelectTabIdRoundtrip() {
        let model = SplitLifecycleCoordinator()
        let closing = TabID()
        let target = TabID()
        model.postCloseSelectTabId[closing] = target

        #expect(model.consumePostCloseSelectTabId(forClosed: closing) == target)
        // Second read is nil; the entry was removed (single-shot semantics).
        #expect(model.consumePostCloseSelectTabId(forClosed: closing) == nil)
        #expect(model.postCloseSelectTabId.isEmpty)
    }

    /// An unrecorded close yields no selection target and does not crash
    /// (legacy `removeValue` on an absent key returns nil).
    @Test("consumePostCloseSelectTabId returns nil for an unrecorded tab")
    func consumeSelectTabIdMissing() {
        let model = SplitLifecycleCoordinator()
        #expect(model.consumePostCloseSelectTabId(forClosed: TabID()) == nil)
    }

    /// `didCloseTab` reads whether the close should clear the split zoom
    /// exactly once and removes the flag (legacy
    /// `postCloseClearSplitZoomTabIds.remove(_:) != nil`).
    @Test("consumeShouldClearSplitZoom reports membership once, then clears it")
    func consumeShouldClearSplitZoomRoundtrip() {
        let model = SplitLifecycleCoordinator()
        let closing = TabID()
        model.postCloseClearSplitZoomTabIds.insert(closing)

        #expect(model.consumeShouldClearSplitZoom(forClosed: closing) == true)
        // Second read is false; the flag was removed (single-shot semantics).
        #expect(model.consumeShouldClearSplitZoom(forClosed: closing) == false)
        #expect(model.postCloseClearSplitZoomTabIds.isEmpty)
    }

    /// A tab that was never zoom-flagged reports false without affecting other
    /// recorded flags.
    @Test("consumeShouldClearSplitZoom returns false for an unflagged tab")
    func consumeShouldClearSplitZoomMissing() {
        let model = SplitLifecycleCoordinator()
        let other = TabID()
        model.postCloseClearSplitZoomTabIds.insert(other)

        #expect(model.consumeShouldClearSplitZoom(forClosed: TabID()) == false)
        #expect(model.postCloseClearSplitZoomTabIds.contains(other))
    }

    /// The two record maps are independent: consuming the selection target
    /// does not touch the zoom-clear flag and vice versa, matching the legacy
    /// god object's two separate stored collections.
    @Test("selection target and zoom-clear flag are tracked independently")
    func mapsAreIndependent() {
        let model = SplitLifecycleCoordinator()
        let closing = TabID()
        let target = TabID()
        model.postCloseSelectTabId[closing] = target
        model.postCloseClearSplitZoomTabIds.insert(closing)

        #expect(model.consumePostCloseSelectTabId(forClosed: closing) == target)
        // The zoom-clear flag is untouched by the selection consume.
        #expect(model.postCloseClearSplitZoomTabIds.contains(closing))
        #expect(model.consumeShouldClearSplitZoom(forClosed: closing) == true)
    }

    /// A non-blank override wins over every title candidate, naming the live
    /// foreground command before the tab's own rename catches up (legacy
    /// `nameOverride` short-circuit in `confirmClosePanel`).
    @Test("closeConfirmationPanelName prefers a non-blank override")
    func closeConfirmNameOverrideWins() {
        let model = SplitLifecycleCoordinator()
        #expect(
            model.closeConfirmationPanelName(
                nameOverride: "sleep",
                customTitle: "Custom",
                title: "Title",
                directory: "/tmp/work"
            ) == "sleep"
        )
    }

    /// A blank override falls through to the custom title, then the cached
    /// title, then the directory's last path component, in that precedence
    /// (legacy `confirmClosePanel` candidate ordering).
    @Test("closeConfirmationPanelName falls through custom, title, directory")
    func closeConfirmNamePrecedence() {
        let model = SplitLifecycleCoordinator()
        #expect(
            model.closeConfirmationPanelName(
                nameOverride: "   ",
                customTitle: "Custom",
                title: "Title",
                directory: "/tmp/work"
            ) == "Custom"
        )
        #expect(
            model.closeConfirmationPanelName(
                nameOverride: nil,
                customTitle: "  ",
                title: "Title",
                directory: "/tmp/work"
            ) == "Title"
        )
        #expect(
            model.closeConfirmationPanelName(
                nameOverride: nil,
                customTitle: nil,
                title: "",
                directory: "/tmp/projects/repo"
            ) == "repo"
        )
    }

    /// Every candidate blank or absent yields no name, so the dialog uses its
    /// generic message (legacy trailing `return nil`).
    @Test("closeConfirmationPanelName returns nil when all candidates are blank")
    func closeConfirmNameNoneSet() {
        let model = SplitLifecycleCoordinator()
        #expect(
            model.closeConfirmationPanelName(
                nameOverride: nil,
                customTitle: "   ",
                title: "",
                directory: nil
            ) == nil
        )
    }
}

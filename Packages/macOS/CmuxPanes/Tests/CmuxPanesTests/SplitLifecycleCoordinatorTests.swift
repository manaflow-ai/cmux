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
}

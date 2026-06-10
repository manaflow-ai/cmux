import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("MobileLocalScrollEngine")
struct MobileLocalScrollEngineTests {
    // MARK: - Routing gates

    @Test("no frame metadata yet forwards to the Mac (older host / raw-byte path)")
    func noMetaForwards() {
        let engine = MobileLocalScrollEngine()
        #expect(engine.flushRoute == .forwardToMac)
    }

    @Test("primary screen with metadata scrolls locally")
    func primaryScrollsLocally() {
        var engine = MobileLocalScrollEngine()
        engine.noteActiveScreen(isAlternate: false)
        #expect(engine.flushRoute == .scrollLocally)
    }

    @Test("alternate screen forwards to the Mac")
    func alternateForwards() {
        var engine = MobileLocalScrollEngine()
        engine.noteActiveScreen(isAlternate: true)
        #expect(engine.flushRoute == .forwardToMac)
    }

    @Test("alt-flip mid-scroll reverts routing but keeps the tracked offset for the snap")
    func altFlipMidScroll() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        _ = engine.applyLocalScroll(lines: 10)
        engine.noteActiveScreen(isAlternate: true)
        #expect(engine.flushRoute == .forwardToMac)
        // The surface is still physically scrolled up; only the snap path may
        // clear the offset, so the next frame still snaps to live.
        #expect(engine.isLocalScrollActive)
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(engine.upRowsExact == 0)
    }

    // MARK: - Offset accumulation and clamps

    @Test("scrolling down below the live bottom clamps at zero")
    func clampsAtLiveBottom() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        _ = engine.applyLocalScroll(lines: 5)
        let outcome = engine.applyLocalScroll(lines: -50)
        #expect(outcome.upRows == 0)
        #expect(!engine.isLocalScrollActive)
    }

    @Test("sub-row residuals accumulate without truncation")
    func subRowResidualsAccumulate() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        for _ in 0..<10 {
            _ = engine.applyLocalScroll(lines: 0.3)
        }
        #expect(abs(engine.upRowsExact - 3.0) < 0.0001)
    }

    @Test("any positive offset is local-scroll active: a sub-row delta already reached the real surface, so live frames must still snap")
    func subRowOffsetStillSnaps() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        _ = engine.applyLocalScroll(lines: 0.4)
        #expect(engine.isLocalScrollActive)
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(engine.upRowsExact == 0)
        // Back at the live bottom exactly: no further snaps.
        #expect(!engine.isLocalScrollActive)
        #expect(!engine.consumeSnapRequest().snapToLive)
    }

    // MARK: - Deeper-fetch trigger

    @Test("reaching the top of held history requests one deeper fetch, not one per flush")
    func fetchFiresOnceAtTop() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        let first = engine.applyLocalScroll(lines: 12)
        #expect(first.requestDeeperFetch)
        // Held pan keeps flushing past the top: deduped by the in-flight latch.
        let second = engine.applyLocalScroll(lines: 3)
        #expect(!second.requestDeeperFetch)
    }

    @Test("scrolling down never requests a fetch")
    func downwardNeverFetches() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 0)
        let outcome = engine.applyLocalScroll(lines: -3)
        #expect(!outcome.requestDeeperFetch)
    }

    @Test("a fresh pan retries a fetch that never produced a snapshot")
    func panBeganRetriesDroppedFetch() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        #expect(!engine.applyLocalScroll(lines: 1).requestDeeperFetch)
        engine.notePanBegan()
        #expect(engine.applyLocalScroll(lines: 1).requestDeeperFetch)
    }

    @Test("a no-growth fetch response closes the ceiling: stop cleanly at the oldest line")
    func noGrowthClosesCeiling() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        // Fetch response: same held rows -> whole scrollback is local now.
        engine.noteFullSnapshot(scrollbackRows: 10)
        engine.notePanBegan()
        #expect(!engine.applyLocalScroll(lines: 5).requestDeeperFetch)
    }

    @Test("a growing fetch response keeps paging in deeper history")
    func growthKeepsPaging() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        engine.noteFullSnapshot(scrollbackRows: 200)
        engine.notePanBegan()
        // Not yet past the new top: no fetch.
        #expect(!engine.applyLocalScroll(lines: 50).requestDeeperFetch)
        // Past the new top: pages in again.
        #expect(engine.applyLocalScroll(lines: 200).requestDeeperFetch)
    }

    @Test("a slow fetch response is still classified as a fetch after a new pan began")
    func slowFetchStillClassified() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        // User starts a new pan before the response lands; the classification
        // latch must survive so the response is measured as a fetch result.
        engine.notePanBegan()
        engine.noteFullSnapshot(scrollbackRows: 10)
        // No growth -> ceiling closed, not misread as a cold attach.
        #expect(!engine.applyLocalScroll(lines: 5).requestDeeperFetch)
    }

    @Test("an alternate-screen full snapshot does not clobber the primary history latches")
    func altSnapshotDoesNotClobberPrimaryLatches() {
        var engine = MobileLocalScrollEngine()
        engine.noteActiveScreen(isAlternate: false)
        engine.noteFullSnapshot(scrollbackRows: 100)
        #expect(engine.applyLocalScroll(lines: 120).requestDeeperFetch)
        // A TUI flips to the alt screen and a full snapshot (e.g. a replay
        // self-heal) lands while it is active: the alt screen has no
        // scrollback, so it must not overwrite the held primary depth or
        // consume the fetch-classification latch.
        engine.noteActiveScreen(isAlternate: true)
        engine.noteFullSnapshot(scrollbackRows: 0)
        #expect(engine.heldScrollbackRows == 100)
        // Back on primary, the fetch's real (grown) snapshot is still
        // classified as a fetch result and restores the reader's position.
        engine.noteActiveScreen(isAlternate: false)
        engine.noteFullSnapshot(scrollbackRows: 300)
        #expect(engine.heldScrollbackRows == 300)
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(snap.restoreUpRows == 120)
    }

    @Test("a cold-attach snapshot re-opens the ceiling")
    func coldAttachReopensCeiling() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        engine.noteFullSnapshot(scrollbackRows: 10) // fetch result: ceiling closed
        engine.noteFullSnapshot(scrollbackRows: 10) // cold attach: ceiling re-opens
        engine.notePanBegan()
        #expect(engine.applyLocalScroll(lines: 1).requestDeeperFetch)
    }

    // MARK: - Snap-to-live and restore

    @Test("at the live bottom an incoming frame does not snap")
    func noSnapAtBottom() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        let snap = engine.consumeSnapRequest()
        #expect(!snap.snapToLive)
        #expect(snap.restoreUpRows == nil)
    }

    @Test("scrolled up, a live frame snaps to live and clears the offset")
    func liveFrameSnaps() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 100)
        _ = engine.applyLocalScroll(lines: 20)
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(snap.restoreUpRows == nil)
        #expect(engine.upRowsExact == 0)
        // Idempotent: the next frame does not snap again.
        #expect(!engine.consumeSnapRequest().snapToLive)
    }

    @Test("a deeper-fetch snapshot restores the reader's position instead of bouncing to bottom")
    func fetchSnapshotRestoresPosition() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        // Fetch response grew history; reader was 12 rows up when it was built.
        engine.noteFullSnapshot(scrollbackRows: 200)
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(snap.restoreUpRows == 12)
        // The tracked offset re-arms to the restored position so a later live
        // frame still snaps the reader back to live.
        #expect(engine.upRowsExact == 12)
        let next = engine.consumeSnapRequest()
        #expect(next.snapToLive)
        #expect(next.restoreUpRows == nil)
    }

    @Test("a cold-attach snapshot clears an armed restore (content may have changed)")
    func coldAttachClearsRestore() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        engine.noteFullSnapshot(scrollbackRows: 200) // fetch result: restore armed
        engine.noteFullSnapshot(scrollbackRows: 50) // cold attach: restore dropped
        let snap = engine.consumeSnapRequest()
        #expect(snap.snapToLive)
        #expect(snap.restoreUpRows == nil)
        #expect(engine.upRowsExact == 0)
    }

    @Test("a fetch response while the reader returned to bottom arms no restore")
    func fetchAtBottomArmsNoRestore() {
        var engine = MobileLocalScrollEngine()
        engine.noteFullSnapshot(scrollbackRows: 10)
        #expect(engine.applyLocalScroll(lines: 12).requestDeeperFetch)
        // Reader returns to the live bottom before the response lands.
        _ = engine.applyLocalScroll(lines: -20)
        engine.noteFullSnapshot(scrollbackRows: 200)
        let snap = engine.consumeSnapRequest()
        #expect(!snap.snapToLive)
        #expect(snap.restoreUpRows == nil)
    }
}

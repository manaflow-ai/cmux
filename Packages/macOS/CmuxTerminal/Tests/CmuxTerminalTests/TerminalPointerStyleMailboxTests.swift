import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@Suite("Complete pointer snapshots")
struct TerminalPointerStyleMailboxTests {
    @Test("a burst retains the last supported shape with one pending wakeup")
    func burstPreservesSemanticsAndBoundsWakeups() async {
        let mailbox = TerminalPointerStyleMailbox()
        let runtimeID = UUID()
        let surfaceID = UUID()
        let generation = mailbox.activate(lifetimeId: runtimeID, surfaceId: surfaceID)
        mailbox.apply(.focusChanged(true))
        for _ in 0..<10_000 {
            for shape in [GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_COPY, GHOSTTY_MOUSE_SHAPE_WAIT] {
                #expect(mailbox.submit(.ghosttyShape(shape, runtimeLifetimeId: runtimeID),
                    surfaceId: surfaceID, lifetimeId: runtimeID, generation: generation))
            }
        }
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_COPY)
        mailbox.finish()
        var wakeups = 0
        for await _ in mailbox.updates { wakeups += 1 }
        #expect(wakeups == 1)
    }

    @Test("mixed link, reset, and end transitions survive a paused consumer")
    func mixedLifecycleBurstMatchesOrderedReduction() {
        let mailbox = TerminalPointerStyleMailbox()
        let runtimeID = UUID()
        let surfaceID = UUID()
        let generation = mailbox.activate(lifetimeId: runtimeID, surfaceId: surfaceID)
        mailbox.apply(.focusChanged(true))
        var ordered = TerminalPointerIntentState()
        ordered.apply(.runtimeActivated(runtimeID))
        ordered.apply(.focusChanged(true))
        let events: [TerminalPointerStyleEvent] = [
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_CROSSHAIR, runtimeLifetimeId: runtimeID),
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_POINTER, runtimeLifetimeId: runtimeID),
            .ghosttyLinkHoverChanged(true, runtimeLifetimeId: runtimeID),
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_WAIT, runtimeLifetimeId: runtimeID),
            .ghosttyLinkHoverChanged(false, runtimeLifetimeId: runtimeID),
            .runtimeReset(runtimeID),
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: runtimeID),
            .ghosttyShape(GHOSTTY_MOUSE_SHAPE_WAIT, runtimeLifetimeId: runtimeID),
            .runtimeEnded(runtimeID),
        ]
        for event in events {
            ordered.apply(event)
            #expect(mailbox.submit(event, surfaceId: surfaceID, lifetimeId: runtimeID, generation: generation))
            #expect(mailbox.snapshot.intent.effectiveShape == ordered.effectiveShape)
            #expect(mailbox.snapshot.intent.ghosttyLinkHoverActive == ordered.ghosttyLinkHoverActive)
        }
        #expect(mailbox.snapshot.intent.activeRuntimeLifetimeId == nil)
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_TEXT)
        #expect(!mailbox.submit(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: runtimeID),
            surfaceId: surfaceID, lifetimeId: runtimeID, generation: generation))
    }

    @Test("old lifetimes, surfaces and generations cannot change replacement state")
    func staleCallbackIdentityIsRejected() {
        let mailbox = TerminalPointerStyleMailbox()
        let oldID = UUID()
        let newID = UUID()
        let surfaceID = UUID()
        let oldGeneration = mailbox.activate(lifetimeId: oldID, surfaceId: surfaceID)
        let newGeneration = mailbox.activate(lifetimeId: newID, surfaceId: surfaceID)
        mailbox.apply(.focusChanged(true))
        mailbox.submit(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: newID),
            surfaceId: surfaceID, lifetimeId: newID, generation: newGeneration)
        let revision = mailbox.snapshot.revision
        #expect(!mailbox.submit(.runtimeEnded(oldID),
            surfaceId: surfaceID, lifetimeId: oldID, generation: oldGeneration))
        #expect(!mailbox.submit(.runtimeReset(newID),
            surfaceId: UUID(), lifetimeId: newID, generation: newGeneration))
        #expect(!mailbox.submit(.runtimeReset(newID),
            surfaceId: surfaceID, lifetimeId: newID, generation: oldGeneration))
        #expect(mailbox.snapshot.revision == revision)
        mailbox.apply(.runtimeEnded(oldID))
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_COPY)
        #expect(mailbox.snapshot.intent.activeRuntimeLifetimeId == newID)
    }

    @Test("concurrent callbacks serialize without losing accepted transitions")
    func concurrentCallbacksAreCountedExactlyOnce() async {
        let mailbox = TerminalPointerStyleMailbox()
        let runtimeID = UUID()
        let surfaceID = UUID()
        let generation = mailbox.activate(lifetimeId: runtimeID, surfaceId: surfaceID)
        mailbox.apply(.focusChanged(true))
        let revision = mailbox.snapshot.revision
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1_000 {
                        mailbox.submit(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: runtimeID),
                            surfaceId: surfaceID, lifetimeId: runtimeID, generation: generation)
                    }
                }
            }
        }
        #expect(mailbox.snapshot.revision == revision + 8_000)
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_COPY)
    }

    @Test("focus epochs reject delayed inputs and snapshots remain immutable")
    func focusEpochAndSnapshotValueIsolation() {
        let mailbox = TerminalPointerStyleMailbox()
        let runtimeID = UUID()
        mailbox.activate(lifetimeId: runtimeID, surfaceId: UUID())
        mailbox.apply(.focusChanged(true))
        mailbox.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: runtimeID))
        let before = mailbox.snapshot
        mailbox.apply(.focusChanged(false))
        mailbox.apply(.focusChanged(true))
        #expect(mailbox.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_POINTER, runtimeLifetimeId: runtimeID),
            focusGeneration: before.focusGeneration) == nil)
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_COPY)
        mailbox.apply(.runtimeEnded(runtimeID))
        #expect(before.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_COPY)
        #expect(mailbox.snapshot.intent.effectiveShape == GHOSTTY_MOUSE_SHAPE_TEXT)
    }

    @Test("observation does not retain the mailbox after its owner releases it")
    func observationFinishesOnRelease() async {
        var mailbox: TerminalPointerStyleMailbox? = TerminalPointerStyleMailbox()
        weak var weakMailbox = mailbox
        let updates = mailbox!.updates
        mailbox = nil
        #expect(weakMailbox == nil)
        weakMailbox = nil
        var count = 0
        for await _ in updates { count += 1 }
        #expect(count == 0)
    }
}

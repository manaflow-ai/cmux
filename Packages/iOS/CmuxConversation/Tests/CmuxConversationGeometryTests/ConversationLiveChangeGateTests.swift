import CmuxConversationCore
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationLiveChangeGateTests {
    @Test func changesApplyAtOnceWhileNoPageMeasures() {
        var gate = ConversationLiveChangeGate()
        let r1 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(!r1)
        let r2 = gate.hold(.typing)
        #expect(!r2)
        let r3 = gate.release()
        #expect(r3 == nil)
    }

    @Test func anArrivalWaitsForTheMeasuredPage() {
        var gate = ConversationLiveChangeGate()
        gate.beginMeasuring()
        let r4 = gate.hold(.typing)
        #expect(r4)
        let r5 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(r5)
        let r6 = gate.finishMeasuring()
        #expect(r6 == .live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(!gate.isMeasuring)
        let r7 = gate.release()
        #expect(r7 == nil)
        // After the page, arrivals apply at once again.
        let r8 = gate.hold(.live(insertedRowIDs: ["b"], sentByMe: false))
        #expect(!r8)
    }

    @Test func myOwnChangesAndOtherKindsNeverWait() {
        var gate = ConversationLiveChangeGate()
        gate.beginMeasuring()
        let r9 = gate.hold(.live(insertedRowIDs: ["mine"], sentByMe: true))
        #expect(!r9)
        let r10 = gate.hold(.live(insertedRowIDs: [], sentByMe: true))
        #expect(!r10)
        let r11 = gate.hold(.reset)
        #expect(!r11)
        let r12 = gate.hold(.prepended)
        #expect(!r12)
        let r13 = gate.hold(.older)
        #expect(!r13)
        let r14 = gate.hold(.listState)
        #expect(!r14)
        #expect(gate.held == nil)
    }

    @Test func heldArrivalsMergeInOrder() {
        var gate = ConversationLiveChangeGate()
        gate.beginMeasuring()
        let r15 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(r15)
        let r16 = gate.hold(.typing)
        #expect(r16)
        let r17 = gate.hold(.live(insertedRowIDs: [], sentByMe: false))
        #expect(r17)
        let r18 = gate.hold(.live(insertedRowIDs: ["b", "c"], sentByMe: false))
        #expect(r18)
        let r19 = gate.release()
        #expect(r19 == .live(insertedRowIDs: ["a", "b", "c"], sentByMe: false))
        // Still measuring: later arrivals keep waiting.
        let r20 = gate.hold(.typing)
        #expect(r20)
        let r21 = gate.finishMeasuring()
        #expect(r21 == .typing)
    }

    @Test func mergingKeepsTheLiveChange() {
        let live = ConversationStoreChange.live(insertedRowIDs: ["a"], sentByMe: false)
        #expect(ConversationLiveChangeGate.merged(.typing, .typing) == .typing)
        #expect(ConversationLiveChangeGate.merged(.typing, live) == live)
        #expect(ConversationLiveChangeGate.merged(live, .typing) == live)
    }

    /// Messages holds transcript updates while the finger drags the
    /// transcript (ChatKit's `scrollViewWillBeginDragging:` to
    /// `scrollViewDidEndDragging:willDecelerate:`), so nothing is inserted,
    /// grown or moved under the finger; what arrived applies at the lift.
    @Test func arrivalsWaitForTheFingerToLift() {
        var gate = ConversationLiveChangeGate()
        gate.beginDragging()
        #expect(gate.isDragging)
        let r22 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(r22)
        let r23 = gate.hold(.typing)
        #expect(r23)
        let r24 = gate.hold(.live(insertedRowIDs: ["mine"], sentByMe: true))
        #expect(!r24)
        let r25 = gate.endDragging()
        #expect(r25 == .live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(!gate.isDragging)
        let r26 = gate.hold(.typing)
        #expect(!r26)
    }

    /// A page measured during a drag, or a drag during a measure: held
    /// changes apply once both are over, never in between.
    @Test func heldChangesWaitForBothThePageAndTheLift() {
        var gate = ConversationLiveChangeGate()
        gate.beginDragging()
        gate.beginMeasuring()
        let r27 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(r27)
        let r28 = gate.finishMeasuring()
        #expect(r28 == nil)
        let r29 = gate.hold(.live(insertedRowIDs: ["b"], sentByMe: false))
        #expect(r29)
        let r30 = gate.endDragging()
        #expect(r30 == .live(insertedRowIDs: ["a", "b"], sentByMe: false))

        gate.beginMeasuring()
        gate.beginDragging()
        let r31 = gate.hold(.typing)
        #expect(r31)
        let r32 = gate.endDragging()
        #expect(r32 == nil)
        let r33 = gate.finishMeasuring()
        #expect(r33 == .typing)
    }
}

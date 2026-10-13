import CmuxConversationCore
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationPageMeasureGateTests {
    @Test func changesApplyAtOnceWhileNoPageMeasures() {
        var gate = ConversationPageMeasureGate()
        let r1 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(!r1)
        let r2 = gate.hold(.typing)
        #expect(!r2)
        let r3 = gate.release()
        #expect(r3 == nil)
    }

    @Test func anArrivalWaitsForTheMeasuredPage() {
        var gate = ConversationPageMeasureGate()
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
        var gate = ConversationPageMeasureGate()
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
        var gate = ConversationPageMeasureGate()
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
        #expect(ConversationPageMeasureGate.merged(.typing, .typing) == .typing)
        #expect(ConversationPageMeasureGate.merged(.typing, live) == live)
        #expect(ConversationPageMeasureGate.merged(live, .typing) == live)
    }
}

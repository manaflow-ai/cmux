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

    /// A status reaching my message while its send flight is in the air
    /// waits for the landing, as it does when it arrives later: the row
    /// hides its status under the flight, so applied mid-flight it grew
    /// unseen and popped in at full size when the flight landed (about 1 s
    /// after the send), and the previous message lost its status before the
    /// new bubble arrived. Measured in the iOS 26.5 simulator: "Delivered"
    /// arrives 85 ms after the send on the conversation simulator's quiet
    /// latency (0.05), 1.5 to 1.8 s after it on its default latency.
    @Test func arrivalsWaitForMySendToLand() {
        var gate = ConversationLiveChangeGate()
        gate.beginFlight()
        let delivered = gate.hold(.live(insertedRowIDs: [], sentByMe: false))
        #expect(delivered)
        let typing = gate.hold(.typing)
        #expect(typing)
        // My own changes (the send's ack) never wait.
        let ack = gate.hold(.live(insertedRowIDs: [], sentByMe: true))
        #expect(!ack)
        let landed = gate.endFlight()
        #expect(landed == .live(insertedRowIDs: [], sentByMe: false))
        #expect(gate.flightsInAir == 0)
        let after = gate.hold(.typing)
        #expect(!after)
    }

    /// Rapid sends fly together: what waited applies once the last one
    /// lands, and not while a page measures or the finger drags.
    @Test func heldChangesWaitForEveryFlight() {
        var gate = ConversationLiveChangeGate()
        gate.beginFlight()
        gate.beginFlight()
        let r1 = gate.hold(.live(insertedRowIDs: ["a"], sentByMe: false))
        #expect(r1)
        let first = gate.endFlight()
        #expect(first == nil)
        let second = gate.endFlight()
        #expect(second == .live(insertedRowIDs: ["a"], sentByMe: false))

        gate.beginFlight()
        gate.beginDragging()
        let r2 = gate.hold(.typing)
        #expect(r2)
        let underTheFinger = gate.endFlight()
        #expect(underTheFinger == nil)
        let lift = gate.endDragging()
        #expect(lift == .typing)

        gate.beginMeasuring()
        gate.beginFlight()
        let r3 = gate.hold(.typing)
        #expect(r3)
        let measured = gate.finishMeasuring()
        #expect(measured == nil)
        let landed = gate.endFlight()
        #expect(landed == .typing)

        // The finger lifting while a send is in the air: what waited
        // follows the landing.
        gate.beginDragging()
        gate.beginFlight()
        let r5 = gate.hold(.typing)
        #expect(r5)
        let liftedMidFlight = gate.endDragging()
        #expect(liftedMidFlight == nil)
        let landedAfterLift = gate.endFlight()
        #expect(landedAfterLift == .typing)

        // A landing with nothing in the air changes nothing.
        let extra = gate.endFlight()
        #expect(extra == nil)
        #expect(gate.flightsInAir == 0)
        let r4 = gate.hold(.typing)
        #expect(!r4)
    }
}

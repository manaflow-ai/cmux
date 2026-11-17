import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// Stage 0's stand-in Home on a bare launch: what its box held at the swap is claimed once, in
/// order (text, caret, sends), its sends reach the Chief once through the launch page's hold, and
/// stage 0's swap signal runs once however often Home says it is up.
@MainActor @Suite
struct HomeLaunchBareTests {
    static let chief = ConversationID("conv_chief")
    static let launch = HomeLaunchChiefSource.conversation
    static let parked = HomeLaunchBareParked(text: "draft", selection: NSRange(location: 2, length: 1), sends: ["one", "two"])

    @Test func parkedContentsAreClaimedOnceAndInOrder() {
        let store = HomeLaunchBareStore()
        store.expect()
        var claims: [HomeLaunchBareParked] = []
        // Claimed before the swap: delivered at the park.
        store.claim { claims.append($0); return true }
        #expect(claims.isEmpty)
        store.park(Self.parked)
        #expect(claims == [Self.parked])
        #expect(store.parked == nil)
        // Again: nothing.
        store.claim { claims.append($0); return true }
        store.park(HomeLaunchBareParked(text: "", selection: NSRange(), sends: []))
        #expect(claims.count == 1)
    }

    @Test func aParkBeforeTheClaimWaitsForIt() {
        let store = HomeLaunchBareStore()
        store.expect()
        store.park(Self.parked)
        var claims: [HomeLaunchBareParked] = []
        // A claimer that is gone keeps them for the next.
        store.claim { _ in false }
        #expect(store.parked == Self.parked)
        store.claim { claims.append($0); return true }
        #expect(claims.map(\.sends) == [["one", "two"]])
        #expect(claims.first?.selection == NSRange(location: 2, length: 1))
    }

    @Test func aClaimWithNothingParkedIsANoOp() {
        let store = HomeLaunchBareStore()
        var called = false
        store.claim { _ in called = true; return true }
        store.park(HomeLaunchBareParked(text: "", selection: NSRange(), sends: []))
        #expect(!called)
        #expect(store.parked == nil)
        // Stage 0 drew no stand-in: a later park of nothing still delivers nothing.
        store.claim { _ in called = true; return true }
        #expect(!called)
    }

    @Test func sendsParkedAtStageZeroReachTheChiefOnceViaTheHold() async throws {
        let hold = LaunchChiefHold()
        let launch = HomeLaunchChiefTests.store(hold)
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        launch.setDraft("mine", for: Self.launch)
        // A send held already (made in the page) goes first.
        let earlier = Task { try await hold.hold([.text("zero")], key: .make()) }
        for _ in 0..<100 where hold.heldParts.isEmpty { await Task.yield() }
        let caret = HomeLaunchComposer.take(Self.parked, launch: launch, hold: hold, home: home)
        #expect(hold.heldParts == [[.text("zero")], [.text("one")], [.text("two")]])
        #expect(launch.draft(for: Self.launch) == "mine\ndraft")
        #expect(caret == NSRange(location: 7, length: 1))
        let sink = Sink()
        hold.resolve(Self.chief) { _, parts, key in sink.parts.append(parts); sink.keys.insert(key) }
        _ = try await earlier.value
        for _ in 0..<1_000 where !hold.heldParts.isEmpty { await Task.yield() }
        #expect(sink.parts == [[.text("zero")], [.text("one")], [.text("two")]])
        #expect(sink.keys.count == 3)
        // Taken again after the hand-off: the sends go to the Chief, the text to its draft.
        _ = HomeLaunchComposer.take(HomeLaunchBareParked(text: "late", selection: NSRange(), sends: ["three"]), launch: launch, hold: hold, home: home)
        for _ in 0..<1_000 where !hold.heldParts.isEmpty { await Task.yield() }
        #expect(sink.parts.last == [.text("three")])
        #expect(sink.parts.count == 4)
        #expect(home.draft(for: Self.chief) == "late")
    }

    @Test func aCancelledHoldKeepsStageZerosTextAsTheDraft() {
        let hold = LaunchChiefHold()
        hold.cancel()
        let launch = HomeLaunchChiefTests.store(hold)
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        #expect(HomeLaunchComposer.take(Self.parked, launch: launch, hold: hold, home: home) == nil)
        #expect(home.draft(for: Self.launch) == "one\ntwo\ndraft")
    }

    @Test func readyRunsOnceEvenWhenBothMarksFire() {
        let gate = HomeLaunchBareReady()
        var runs = 0
        gate.arm { runs += 1 }
        gate.fire()  // home.launch_composer
        gate.fire()  // window_usable
        #expect(runs == 1)
        // Fired before stage 0 armed it: it runs at the arm, once.
        let early = HomeLaunchBareReady()
        early.fire()
        early.fire()
        early.arm { runs += 1 }
        early.arm { runs += 1 }
        #expect(runs == 2)
    }

    @Test func theBoxSitsWhereHomesDoes() {
        let layout = HomeLaunchBareLayout(bounds: CGRect(x: 0, y: 0, width: 1100, height: 720))
        #expect(layout.column == CGRect(x: 529, y: 0, width: 571, height: 720))
        let field = layout.field(lines: 1)
        #expect(field.minX == 580)
        #expect(field.width == 469)
        #expect(field.maxY == 709)
        #expect(layout.field(lines: 100).height == HomeLaunchBareLayout.fieldMaxHeight)
    }
}

/// What the hold handed to the Chief.
@MainActor
private final class Sink {
    var parts: [[MessagePart]] = []
    var keys: Set<IdempotencyKey> = []
}

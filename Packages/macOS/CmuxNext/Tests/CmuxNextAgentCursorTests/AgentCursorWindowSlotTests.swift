import CmuxAgentCursor
import QuartzCore
import Testing
@testable import CmuxNextAgentCursor

@MainActor
private final class Placements: AgentCursorTargetResolving {
    var placements: [String: AgentCursorPlacement] = [:]
    func placement(forTarget targetID: String) -> AgentCursorPlacement { placements[targetID] ?? .elsewhere }
}

private func click(_ seq: UInt64, target: String) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: "s1", targetID: target, seq: seq, kind: .click, space: .viewport,
                         point: .init(x: 20, y: 30), tMs: Double(seq))
}

@MainActor
@Suite struct AgentCursorWindowSlotTests {
    private let viewport = CGRect(x: 260, y: 80, width: 600, height: 500)

    private func slot(_ placements: Placements) -> (AgentCursorWindowSlot, CALayer, () -> Int) {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        var made = 0
        let slot = AgentCursorWindowSlot(resolver: placements) {
            made += 1
            return layer
        }
        return (slot, layer, { made })
    }

    @Test func leaseAndVisibilityChangesNeverMakeTheLayer() {
        let (slot, _, made) = slot(Placements())
        slot.leaseDidChange(session: "s1", state: .paused)
        slot.placementsDidChange(target: "t1")
        slot.endSession("s1")
        #expect(made() == 0)
        #expect(slot.stack == nil)
    }

    @Test func inputThisWindowDoesNotDrawMakesNothing() {
        let (slot, _, made) = slot(Placements())
        slot.publish(click(0, target: "t9"))
        #expect(made() == 0)
    }

    @Test func theFirstDrawnInputMakesOneStackInContentViewCoordinates() throws {
        let placements = Placements()
        placements.placements["t1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let (slot, layer, made) = slot(placements)
        slot.publish(click(0, target: "t1"))
        slot.publish(click(1, target: "t1"))
        #expect(made() == 1)
        #expect(layer.sublayers?.count == 1)
        let cursor = try #require(slot.stack?.host.cursorLayer(for: "s1"))
        #expect(cursor.root.position == CGPoint(x: 280, y: 110), "viewport origin + page point, window content-view space")
    }

    @Test func laterChangesReachTheStackOnceItExists() throws {
        let placements = Placements()
        placements.placements["t1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let (slot, layer, _) = slot(placements)
        var untracked: [String] = []
        slot.onUntrack = { untracked.append($0) }
        slot.publish(click(0, target: "t1"))
        placements.placements["t1"] = .hidden(anchor: CGRect(x: 10, y: 200, width: 220, height: 28))
        slot.placementsDidChange(target: "t1")
        let cursor = try #require(slot.stack?.host.cursorLayer(for: "s1"))
        #expect(cursor.showsIndicator, "a sidebar-row anchor draws at the row in the window layer")
        #expect(cursor.root.position == CGPoint(x: 120, y: 214))
        slot.leaseDidChange(session: "s1", state: nil)
        #expect(layer.sublayers?.isEmpty ?? true)
        #expect(untracked == ["t1"])
    }

    @Test func thePublisherExistsBeforeTheStackAndDropsReplays() throws {
        let placements = Placements()
        placements.placements["t1"] = .visible(content: viewport, clip: viewport, zoom: 1, magnification: 1)
        let (slot, layer, made) = slot(placements)
        _ = slot.publisher
        #expect(made() == 0, "the input bridge holds the publisher of every window; no layer until it draws")
        slot.publisher.publish(click(0, target: "t1"))
        slot.publisher.publish(AutomationInputEvent(sessionID: "s1", targetID: "t1", seq: 0, kind: .click, space: .viewport,
                                                    point: .init(x: 300, y: 300), tMs: 9))
        let cursor = try #require(slot.stack?.host.cursorLayer(for: "s1"))
        #expect(cursor.root.position == CGPoint(x: 280, y: 110), "a replayed seq is dropped")
        #expect(layer.sublayers?.count == 1)
    }
}

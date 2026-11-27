import AppKit
import CmuxNextDesign
@testable import CmuxNextFloating
import Foundation
import Testing

/// Leo 2026-11-07: the Chief looks left, right, up and down while thinking, and leans the way it is
/// dragged. The rows each direction draws, the drag's dominant direction, and the layer's poses.
@MainActor @Suite(.serialized) struct ChiefPetDirectionTests {
    static func sprite(_ directions: String, faces: String = "right", rows: Int = 14) -> ChiefPetSprite? {
        let json = #"{"format":"cmux-avatar/1","frame":{"width":8,"height":8},"fps":8,"faces":"\#(faces)","states":{"idle":{"row":0,"frames":4},"thinking":{"row":2,"frames":4,"fps":5}}\#(directions)}"#
        return ChiefPetSprite(sheet: ChiefPetSpriteTests.sheet(columns: 8, rows: rows), json: Data(json.utf8))
    }

    @Test func everyAnimatedSetLooksAndLeansAllFourWays() throws {
        for mascot in [ChiefPetMascot.mochi, .captain, .sprout, .bolt] {
            let sprite = try #require(mascot.sprite)
            #expect(sprite.has(.look) && sprite.has(.drag))
            let look = ChiefPetDirection.allCases.map { sprite.track(.look, toward: $0, facingRight: true)?.row }
            let drag = ChiefPetDirection.allCases.map { sprite.track(.drag, toward: $0, facingRight: true)?.row }
            #expect(look == [6, 7, 8, 9], "\(mascot.rawValue) looks left, right, up, down on rows 6 to 9")
            #expect(drag == [10, 11, 12, 13], "\(mascot.rawValue) leans on rows 10 to 13")
            #expect(sprite.track(.look, toward: .left, facingRight: true)?.frames == sprite.track(.thinking, facingRight: true).frames)
            #expect(sprite.frame(row: 13, 0)?.width == 32)
            // Facing left, the sides swap rows and mirror: looking left is the look-right row, mirrored.
            #expect(sprite.track(.look, toward: .left, facingRight: false).map { [$0.row, $0.mirrored ? 1 : 0] } == [7, 1])
            #expect(sprite.track(.drag, toward: .up, facingRight: false).map { [$0.row, $0.mirrored ? 1 : 0] } == [12, 1])
        }
    }

    @Test func aMissingSideBorrowsTheOtherAndOldManifestsHaveNone() throws {
        let old = try #require(Self.sprite(""))
        #expect(!old.has(.look) && !old.has(.drag))
        #expect(old.track(.look, toward: .left, facingRight: true) == nil)
        let half = try #require(Self.sprite(#","directions":{"drag":{"right":{"row":11,"frames":4,"fps":8}}}"#))
        #expect(half.track(.drag, toward: .right, facingRight: true) == .init(row: 11, frames: 4, fps: 8, loop: true, mirrored: false))
        #expect(half.track(.drag, toward: .left, facingRight: true) == .init(row: 11, frames: 4, fps: 8, loop: true, mirrored: true))
        #expect(half.track(.drag, toward: .left, facingRight: false)?.mirrored == true, "facing left: the right row, mirrored")
        #expect(half.track(.drag, toward: .right, facingRight: false)?.mirrored == false, "facing left, pulled right: the right row as drawn")
        #expect(half.track(.drag, toward: .up, facingRight: true) == nil, "no up row: the state draws")
        // A row past the sheet has no frames: no row.
        let short = try #require(Self.sprite(#","directions":{"look":{"left":{"row":11,"frames":4}}}"#, rows: 4))
        #expect(short.track(.look, toward: .left, facingRight: true) == nil)
    }

    @Test func theDragPicksItsDominantDirection() {
        #expect(ChiefPetDirection.dominant(dx: 10, dy: 3) == .right)
        #expect(ChiefPetDirection.dominant(dx: -10, dy: 9) == .left)
        #expect(ChiefPetDirection.dominant(dx: 2, dy: 8) == .up, "screen points: y grows up")
        #expect(ChiefPetDirection.dominant(dx: -1, dy: -6) == .down)
        #expect(ChiefPetDirection.dominant(dx: 5, dy: -5) == .right, "a tie goes to the side")
        #expect(ChiefPetDirection.dominant(dx: 1, dy: -1, minimum: 3) == nil, "a jitter turns nothing")
    }

    /// Thinking looks around in one looping keyframe animation; without motion it stands on thinking's first frame.
    /// A working chat is the Chief thinking too (Leo 2026-11-07: "the left, right, up, down thinking"): the
    /// pet's states never say `.thinking` for a chat at work, so working looks around the same way.
    @Test func thinkingLooksAroundOnlyWhileItMayMove() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let mochi = try #require(ChiefPetMascot.mochi.sprite)
        let drawn = ChiefPetSpriteLayer()
        drawn.show(mochi, state: .thinking, facingRight: true, moving: true)
        #expect(drawn.pose == .lookTour)
        let steps = try #require(drawn.layer.animation(forKey: ChiefPetSpriteLayer.animationKey) as? CAKeyframeAnimation)
        // Each look: two passes of thinking (6 frames) and one look pass (6 frames), four looks.
        #expect(steps.values?.count == 4 * (2 * 6 + 6))
        #expect(steps.repeatCount == .infinity)
        drawn.show(mochi, state: .thinking, facingRight: true, moving: false)
        #expect(drawn.pose == .state)
        #expect(!drawn.isMoving)
        drawn.show(mochi, state: .working, facingRight: true, moving: true)
        #expect(drawn.pose == .lookTour, "a working chat looks around as it thinks")
        drawn.show(mochi, state: .waiting, facingRight: true, moving: true)
        #expect(drawn.pose == .state, "waiting on the person never looks around")
        // Reduce Motion: no tour runs.
        Motion.reduceMotionOverride = true
        drawn.show(mochi, state: .thinking, facingRight: false, moving: true)
        #expect(!drawn.isMoving)
    }

    /// A drag leans the pet the way it is pulled and the drop draws its state again; Reduce Motion never leans.
    @Test func aDragLeansTowardThePullAndTheDropRestores() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let panel = ChiefPetPanel(defaults: ChiefPetSpriteTests.defaults())
        defer { panel.close() }
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        let mochi = try #require(ChiefPetMascot.mochi.sprite)
        panel.pet.animate(mochi, state: .idle, facingRight: true, moving: false)
        let pet = panel.pet
        var poses: [ChiefPetSpriteLayer.Pose] = []
        pet.onDragMoved = { poses.append(pet.sprite.pose) }
        var pointer = CGPoint(x: 220, y: 230)
        pet.pointer = { pointer }
        pet.layoutSubtreeIfNeeded()
        let spot = pet.convert(CGPoint(x: pet.characterFrame.midX, y: pet.characterFrame.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: spot, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pet.mouseDown(with: event)
        for point in [CGPoint(x: 240, y: 232), CGPoint(x: 241, y: 233), CGPoint(x: 243, y: 260), CGPoint(x: 220, y: 262)] {
            pointer = point
            pet.mouseDragged(with: event)
        }
        #expect(poses == [.drag(.right), .drag(.right), .drag(.up), .drag(.left)], "a 1 pt jitter keeps the lean")
        pet.mouseUp(with: event)
        #expect(pet.sprite.pose == .state)
        #expect(pet.sprite.dragging == nil)
        // A state change mid-drag keeps the lean; the drop shows the new state.
        pet.sprite.drag(.down)
        pet.animate(mochi, state: .working, facingRight: true, moving: false)
        #expect(pet.sprite.pose == .drag(.down))
        pet.sprite.drag(nil)
        #expect(pet.sprite.pose == .state && pet.sprite.shown?.state == .working)
        // Reduce Motion turning on mid-drag: the next redraw drops the lean.
        pet.sprite.drag(.up)
        #expect(pet.sprite.pose == .drag(.up))
        Motion.reduceMotionOverride = true
        pet.animate(mochi, state: .idle, facingRight: true, moving: false)
        #expect(pet.sprite.pose == .state)
        pet.sprite.drag(nil)
        // Reduce Motion: a drag never leans.
        pet.sprite.drag(.left)
        #expect(pet.sprite.pose == .state)
    }
}
